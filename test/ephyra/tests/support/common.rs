use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::time::Duration;

fn port() -> u16 {
    static PORT: OnceLock<u16> = OnceLock::new();
    *PORT.get_or_init(|| {
        let mut child = Command::new("mise")
            .args(["exec", "ruby@4.0.9", "--", "bundle", "exec", "ruby"])
            .arg(concat!(env!("CARGO_MANIFEST_DIR"), "/http_server.rb"))
            .current_dir(concat!(env!("CARGO_MANIFEST_DIR"), "/../.."))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("start ruby");
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        std::mem::forget(child);
        line.trim().parse().expect("port")
    })
}

struct Input<'a> {
    bytes: &'a [u8],
    at: usize,
}

const ALPHABET: [u8; 12] = [
    b'a', b'\r', b'\n', b'0', b';', b'5', b' ', 0xff, b'f', b':', b'\t', b'-',
];

impl Input<'_> {
    fn next(&mut self) -> usize {
        let value = self.bytes.get(self.at).copied().unwrap_or(0);
        self.at += 1;
        value as usize
    }

    fn data(&mut self, len: usize) -> Vec<u8> {
        (0..len).map(|_| ALPHABET[self.next() % 8]).collect()
    }

    fn cuts(&mut self, len: usize) -> Vec<usize> {
        let mut cuts = Vec::new();
        for _ in 0..self.next() % 6 {
            let at = (self.next() * 256 + self.next()) % len.max(1);
            if at > 0 {
                cuts.push(at);
            }
        }
        cuts.sort();
        cuts.dedup();
        cuts
    }
}

struct Expected {
    head: bool,
    status: u16,
    body: String,
}

struct Case {
    stream: Vec<u8>,
    expected: Vec<Expected>,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn echo_requests(input: &mut Input) -> Case {
    let methods = ["POST", "GET", "PUT", "HEAD", "DELETE", "OPTIONS"];
    let paths = [("/", ""), ("/a", ""), ("/a/b", "x=1"), ("/%20", "q=%41")];
    let mut stream = Vec::new();
    let mut expected = Vec::new();
    let count = 1 + input.next() % 4;
    for _ in 0..count {
        let method = methods[input.next() % methods.len()];
        let (path, query) = paths[input.next() % paths.len()];
        let flags = input.next();
        let target = if query.is_empty() {
            path.to_string()
        } else {
            format!("{path}?{query}")
        };
        stream.extend(format!("{method} {target} HTTP/1.1\r\nHost: example.com\r\n").bytes());
        let close = flags & 1 == 1 && flags & 2 == 2;
        if close {
            stream.extend(b"Connection: close\r\n");
        }
        let mut body = Vec::new();
        match input.next() % 4 {
            0 => stream.extend(b"\r\n"),
            1 => {
                let len = input.next() % 40;
                body = input.data(len);
                if flags & 4 == 4 {
                    stream.extend(b"Expect: 100-continue\r\n");
                }
                stream.extend(format!("Content-Length: {}\r\n\r\n", body.len()).bytes());
                stream.extend(&body);
            }
            _ => {
                if flags & 4 == 4 {
                    stream.extend(b"Expect: 100-continue\r\n");
                }
                stream.extend(b"Transfer-Encoding: chunked\r\n\r\n");
                for _ in 0..input.next() % 4 {
                    let style = input.next();
                    let len = 1 + input.next() % 12;
                    let part = input.data(len);
                    let size = match style % 3 {
                        0 => format!("{len:x}"),
                        1 => format!("{len:X}"),
                        _ => format!("00{len:x}"),
                    };
                    stream.extend(size.bytes());
                    if style & 8 == 8 {
                        stream.extend(b";a=b");
                    }
                    stream.extend(b"\r\n");
                    stream.extend(&part);
                    stream.extend(b"\r\n");
                    body.extend(part);
                }
                stream.extend(b"0\r\n");
                if flags & 8 == 8 {
                    stream.extend(b"X-T: 1\r\n");
                }
                stream.extend(b"\r\n");
            }
        }
        expected.push(Expected {
            head: method == "HEAD",
            status: 200,
            body: if method == "HEAD" {
                String::new()
            } else {
                format!("{method}|{path}|{query}|{}", hex(&body))
            },
        });
        if close {
            break;
        }
    }
    Case { stream, expected }
}

fn exchange(stream: &[u8], cuts: &[usize]) -> Vec<u8> {
    let mut socket = TcpStream::connect(("127.0.0.1", port())).expect("connect");
    socket.set_nodelay(true).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut from = 0;
    for &cut in cuts.iter().chain(std::iter::once(&stream.len())) {
        if socket.write_all(&stream[from..cut]).is_err() {
            break;
        }
        from = cut;
        std::thread::sleep(Duration::from_millis(3));
    }
    let _ = socket.shutdown(Shutdown::Write);
    let mut response = Vec::new();
    if let Err(error) = socket.read_to_end(&mut response) {
        if error.kind() != std::io::ErrorKind::ConnectionReset {
            panic!(
                "no end of response: {error}; got {:?}",
                String::from_utf8_lossy(&response)
            );
        }
    }
    response
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

#[derive(Debug, PartialEq, Clone)]
struct Response {
    status: u16,
    body: String,
    persistent: bool,
}

fn parse(mut raw: &[u8], heads: &[bool]) -> Result<Vec<Response>, String> {
    let mut responses = Vec::new();
    let mut index = 0;
    while !raw.is_empty() {
        let end = find(raw, b"\r\n\r\n").ok_or("unterminated response head")?;
        let head = String::from_utf8_lossy(&raw[..end]).to_string();
        raw = &raw[end + 4..];
        let status: u16 = head
            .get(9..12)
            .and_then(|s| s.parse().ok())
            .ok_or(format!("bad status line in {head:?}"))?;
        if status < 200 {
            continue;
        }
        let is_head = heads.get(index).copied().unwrap_or(false);
        index += 1;
        let header = |name: &str| {
            head.lines().skip(1).find_map(|line| {
                let (key, value) = line.split_once(':')?;
                key.eq_ignore_ascii_case(name)
                    .then(|| value.trim().to_ascii_lowercase())
            })
        };
        let connection = header("connection").unwrap_or_default();
        let mut persistent = if head.starts_with("HTTP/1.1") {
            connection != "close"
        } else {
            connection == "keep-alive"
        };
        let mut body = Vec::new();
        if is_head || status == 204 || status == 304 {
        } else if let Some(length) = header("content-length") {
            let length: usize = length.parse().map_err(|_| "bad content-length")?;
            if raw.len() < length {
                return Err(format!("short body in response {index}"));
            }
            body = raw[..length].to_vec();
            raw = &raw[length..];
        } else if header("transfer-encoding").is_some() {
            loop {
                let line = find(raw, b"\r\n").ok_or("unterminated chunk size")?;
                let size = usize::from_str_radix(&String::from_utf8_lossy(&raw[..line]), 16)
                    .map_err(|_| "bad chunk size")?;
                raw = &raw[line + 2..];
                if raw.len() < size + 2 {
                    return Err("short chunk".into());
                }
                body.extend(&raw[..size]);
                raw = &raw[size + 2..];
                if size == 0 {
                    break;
                }
            }
        } else {
            if persistent {
                return Err(format!(
                    "response {index} stays open with no content-length or chunking: {head:?}"
                ));
            }
            body = raw.to_vec();
            raw = &[];
        }
        if raw.is_empty() {
            persistent = false;
        }
        responses.push(Response {
            status,
            body: String::from_utf8_lossy(&body).to_string(),
            persistent,
        });
    }
    Ok(responses)
}

fn show(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).to_string()
}

