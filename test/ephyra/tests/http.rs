#![allow(dead_code)]

include!("support/common.rs");

#[ephyra::test]
fn pipelined_requests_echo_their_bodies(bytes: Vec<u8>) {
    let mut input = Input {
        bytes: &bytes,
        at: 0,
    };
    let case = echo_requests(&mut input);
    let cuts = input.cuts(case.stream.len());
    let heads: Vec<bool> = case.expected.iter().map(|e| e.head).collect();
    for cuts in [&[][..], &cuts[..]] {
        let raw = exchange(&case.stream, cuts);
        let responses = parse(&raw, &heads).unwrap_or_else(|error| {
            panic!(
                "{error}\nrequest {:?}\ncuts {cuts:?}\nresponse {:?}",
                show(&case.stream),
                show(&raw)
            )
        });
        let actual: Vec<(u16, &str)> = responses
            .iter()
            .map(|r| (r.status, r.body.as_str()))
            .collect();
        let wanted: Vec<(u16, &str)> = case
            .expected
            .iter()
            .map(|e| (e.status, e.body.as_str()))
            .collect();
        assert_eq!(
            actual,
            wanted,
            "request {:?} cuts {cuts:?}",
            show(&case.stream)
        );
    }
}

fn verdict(stream: &[u8], cuts: &[usize]) -> Result<Vec<(u16, String)>, String> {
    let raw = exchange(stream, cuts);
    let responses = parse(&raw, &[]).map_err(|error| format!("{error}: {:?}", show(&raw)))?;
    Ok(responses
        .into_iter()
        .map(|r| {
            let body = if r.status == 200 {
                r.body
            } else {
                String::new()
            };
            (r.status, body)
        })
        .collect())
}

#[ephyra::test]
fn segmentation_does_not_change_the_verdict(bytes: Vec<u8>) {
    let mut input = Input {
        bytes: &bytes,
        at: 0,
    };
    let mut stream = echo_requests(&mut input).stream;
    stream = stream
        .iter()
        .map(|b| if *b == b'H' && false { b'h' } else { *b })
        .collect();
    for _ in 0..1 + input.next() % 3 {
        let at = (input.next() * 256 + input.next()) % stream.len();
        let byte = ALPHABET[input.next() % ALPHABET.len()];
        match input.next() % 3 {
            0 => stream[at] = byte,
            1 => stream.insert(at, byte),
            _ => {
                stream.remove(at);
            }
        }
        if stream.is_empty() {
            return;
        }
    }
    if find(&stream, b"HEAD").is_some() {
        return;
    }
    let cuts = input.cuts(stream.len());
    if cuts.is_empty() {
        return;
    }
    let whole = verdict(&stream, &[]);
    let split = verdict(&stream, &cuts);
    if whole == split {
        return;
    }
    for _ in 0..3 {
        if verdict(&stream, &[]) != whole || verdict(&stream, &cuts) != split {
            return;
        }
    }
    panic!(
        "request {:?}\ncuts {cuts:?}\nwhole {whole:?}\nsplit {split:?}",
        show(&stream)
    );
}

#[ephyra::test]
fn app_responses_are_framed(bytes: Vec<u8>) {
    let mut input = Input {
        bytes: &bytes,
        at: 0,
    };
    let statuses = [200, 201, 204, 304, 404, 500];
    let mut stream = Vec::new();
    let mut expected = Vec::new();
    let mut persistent = Vec::new();
    for _ in 0..1 + input.next() % 4 {
        let status = statuses[input.next() % statuses.len()];
        let kind = input.next() % 4;
        let count = input.next() % 4;
        let size = [0, 1, 7, 3000, 70000][input.next() % 5];
        let length = input.next() % 2;
        let flags = input.next();
        let head = flags & 1 == 1;
        let old = flags & 2 == 2;
        let connection =
            ["", "Connection: keep-alive\r\n", "Connection: close\r\n"][input.next() % 3];
        let method = if head { "HEAD" } else { "GET" };
        let version = if old { "HTTP/1.0" } else { "HTTP/1.1" };
        stream.extend(
            format!(
                "{method} / {version}\r\nHost: example.com\r\n{connection}X-Plan: {status}.{kind}.{count}.{size}.{length}\r\n\r\n"
            )
            .bytes(),
        );
        let mut body = String::new();
        if !head && status != 204 && status != 304 {
            for i in 0..count {
                body.push_str(&(if i % 2 == 0 { "x" } else { "yz" }).repeat(size));
            }
        }
        expected.push(Expected { head, status, body });
        let stays = if old {
            connection.contains("keep-alive")
        } else {
            !connection.contains("close")
        };
        persistent.push(stays);
        if !stays {
            break;
        }
    }
    let heads: Vec<bool> = expected.iter().map(|e| e.head).collect();
    let raw = exchange(&stream, &[]);
    let request = show(&stream);
    let short = |raw: &[u8]| show(&raw[..raw.len().min(600)]);
    let responses = parse(&raw, &heads).unwrap_or_else(|error| {
        ephyra::signature(
            error
                .split(':')
                .next()
                .unwrap_or("parse")
                .replace(char::is_numeric, "N"),
        );
        panic!("{error}\nrequest {request:?}\nresponse {:?}", short(&raw))
    });
    assert!(!responses.is_empty(), "no response to {request:?}");
    assert!(
        responses.len() <= expected.len(),
        "extra responses to {request:?}"
    );
    for (index, response) in responses.iter().enumerate() {
        let want = &expected[index];
        if response.status != want.status {
            ephyra::signature(format!("status {} for {}", response.status, want.status));
        }
        assert_eq!(
            response.status, want.status,
            "status of response {index} to {request:?}"
        );
        if response.body != want.body {
            ephyra::signature(format!(
                "body {} for status {}",
                if response.body.len() > want.body.len() {
                    "long"
                } else {
                    "short"
                },
                want.status
            ));
        }
        assert!(
            response.body == want.body,
            "body of response {index} to {request:?}: {} bytes, wanted {}; response {:?}",
            response.body.len(),
            want.body.len(),
            short(&raw)
        );
    }
    if responses.len() < expected.len() {
        let last = &responses[responses.len() - 1];
        let raw_last_closed = !show(&raw).to_ascii_lowercase().contains("keep-alive")
            || show(&raw)
                .to_ascii_lowercase()
                .contains("connection: close");
        assert!(
            !last.persistent || raw_last_closed,
            "connection dropped {} of {} responses to {request:?}",
            expected.len() - responses.len(),
            expected.len()
        );
    }
}

fn status_and_body(raw: &[u8]) -> (u16, String) {
    let text = show(raw);
    let status = text.get(9..12).and_then(|s| s.parse().ok()).unwrap_or(0);
    let body = text.split_once("\r\n\r\n").map(|(_, b)| b).unwrap_or("");
    (status, body.to_string())
}

#[ephyra::test]
fn valid_targets_and_hosts_reach_the_app(bytes: Vec<u8>) {
    let mut input = Input {
        bytes: &bytes,
        at: 0,
    };
    let host = ["example.com", "localhost", "127.0.0.1", "[::1]"][input.next() % 4];
    let (port, want_port) =
        [("", "80"), (":8080", "8080"), (":", "80"), (":443", "443")][input.next() % 4];
    let (path, query) = [
        ("/", ""),
        ("/a", "b=1"),
        ("", ""),
        ("", "b=1"),
        ("/a//b", ""),
    ][input.next() % 5];
    let absolute = input.next() % 2 == 1;
    if !absolute && path.is_empty() {
        return;
    }
    let mut target = if absolute {
        format!("http://{host}{port}{path}")
    } else {
        path.to_string()
    };
    if !query.is_empty() {
        target.push_str(&format!("?{query}"));
    }
    let request = format!(
        "GET {target} HTTP/1.1\r\nHost: {host}{port}\r\nX-Env: 1\r\nConnection: close\r\n\r\n"
    );
    let raw = exchange(request.as_bytes(), &[]);
    let (status, body) = status_and_body(&raw);
    let want_path = if path.is_empty() { "/" } else { path };
    let want = format!("{want_port}|{host}|{want_path}|{query}");
    if status != 200 {
        ephyra::signature(body.lines().next().unwrap_or("no body").to_string());
    } else if body != want {
        ephyra::signature("wrong env");
    }
    assert_eq!(
        (status, body.lines().next().unwrap_or("")),
        (200, want.as_str()),
        "request {request:?}"
    );
}

#[ephyra::test]
fn early_hints_send_each_value(bytes: Vec<u8>) {
    let mut input = Input {
        bytes: &bytes,
        at: 0,
    };
    let count = 1 + input.next() % 3;
    let array = input.next() % 2;
    let request = format!(
        "GET / HTTP/1.1\r\nHost: example.com\r\nX-Hints: {count}.{array}\r\nConnection: close\r\n\r\n"
    );
    let raw = show(&exchange(request.as_bytes(), &[]));
    let first = raw.split("\r\n\r\n").next().unwrap_or("");
    let lines: Vec<String> = first.split("\r\n").map(str::to_string).collect();
    let mut want = vec!["HTTP/1.1 103 Early Hints".to_string()];
    want.extend((0..count).map(|i| format!("link: </{i}.css>; rel=preload")));
    assert_eq!(lines, want, "request {request:?}");
}

#[ephyra::test(tests = 40)]
fn expect_continue_is_answered_before_the_body(bytes: Vec<u8>) {
    let mut input = Input {
        bytes: &bytes,
        at: 0,
    };
    let value = ["100-continue", "100-Continue", "100-CONTINUE"][input.next() % 3];
    let version = ["HTTP/1.1", "HTTP/1.0"][input.next() % 2];
    let head = format!(
        "POST / {version}\r\nHost: example.com\r\nConnection: close\r\nExpect: {value}\r\nContent-Length: 2\r\n\r\n"
    );
    let mut socket = TcpStream::connect(("127.0.0.1", port())).expect("connect");
    socket.write_all(head.as_bytes()).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_millis(150)))
        .unwrap();
    let mut buffer = [0u8; 256];
    let interim = match socket.read(&mut buffer) {
        Ok(n) => show(&buffer[..n]),
        Err(_) => String::new(),
    };
    socket.write_all(b"ab").unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut rest = Vec::new();
    let _ = socket.read_to_end(&mut rest);
    assert!(
        show(&rest).ends_with("POST|/||6162"),
        "final response {:?}",
        show(&rest)
    );
    let got = interim.starts_with("HTTP/1.1 100 Continue\r\n\r\n");
    let want = version == "HTTP/1.1";
    if got != want {
        ephyra::signature(if want {
            "no 100 Continue"
        } else {
            "100 Continue to HTTP/1.0"
        });
    }
    assert_eq!(got, want, "request {head:?} interim {interim:?}");
}

#[ephyra::test]
fn chunk_sizes_never_cause_a_server_error(bytes: Vec<u8>) {
    let mut input = Input {
        bytes: &bytes,
        at: 0,
    };
    let digits = b"0123456789abcdefABCDEF";
    let size: String = (0..1 + input.next() % 30)
        .map(|_| digits[input.next() % digits.len()] as char)
        .collect();
    let request = format!(
        "POST / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n{size}\r\nab\r\n0\r\n\r\n"
    );
    let raw = exchange(request.as_bytes(), &[]);
    let (status, body) = status_and_body(&raw);
    assert!(
        status < 500,
        "request {request:?}\nstatus {status}: {:?}",
        body.lines().next()
    );
    if u128::from_str_radix(&size, 16) == Ok(2) {
        assert_eq!(
            (status, body.as_str()),
            (200, "POST|/||6162"),
            "request {request:?}"
        );
    }
}

#[ephyra::test]
fn valid_requests_give_a_rack_env_that_passes_lint(bytes: Vec<u8>) {
    let mut input = Input {
        bytes: &bytes,
        at: 0,
    };
    let targets = [
        "/",
        "/a",
        "/a/b/",
        "/?",
        "/?a=b&c",
        "/%7Euser",
        "/a;p=1",
        "/a:b",
        "/@",
        "//a",
        "/a//b",
        "/.",
        "/..",
        "/a%2Fb",
        "*",
        "http://example.com/",
        "http://example.com",
        "http://example.com?x=1",
        "http://example.com/?",
        "http://EXAMPLE.com:80/a",
        "https://example.com/a",
        "http://u@example.com/a",
        "http://[::1]/a",
    ];
    let hosts = [
        "example.com",
        "example.com:80",
        "EXAMPLE.com",
        "[::1]",
        "[::1]:8080",
        "127.0.0.1:3000",
        "example.com.",
    ];
    let headers = [
        "Content-Length: 0",
        "Content-Type: text/plain",
        "Content-Type:",
        "Version: HTTP/2.0",
        "Https: on",
        "X-Forwarded-Proto: https",
        "X-Forwarded-Proto: http, https",
        "X-Forwarded-Ssl: on",
        "X-Forwarded-Scheme: https",
        "Accept: */*",
        "X-Forwarded-Proto: wss",
        "Cookie: a=b",
        "Content-Length: 00",
        "Script-Name: /x",
        "Path-Info: /x",
        "Server-Port: abc",
        "Rack.Input: x",
        "Content-Type: a\tb",
        "X-Forwarded-Proto:",
    ];
    let target = targets[input.next() % targets.len()];
    let method = if target == "*" {
        "OPTIONS"
    } else {
        ["GET", "POST", "OPTIONS", "DELETE", "PATCH", "PUT"][input.next() % 6]
    };
    let host = hosts[input.next() % hosts.len()];
    let mut request =
        format!("{method} {target} HTTP/1.1\r\nHost: {host}\r\nX-Env: 1\r\nConnection: close\r\n");
    let mut lengths = 0;
    for _ in 0..input.next() % 4 {
        let header = headers[input.next() % headers.len()];
        if header.starts_with("Content-Length") {
            lengths += 1;
            if lengths > 1 {
                continue;
            }
        }
        request.push_str(header);
        request.push_str("\r\n");
    }
    request.push_str("\r\n");
    let raw = exchange(request.as_bytes(), &[]);
    let (status, body) = status_and_body(&raw);
    if status != 200 {
        ephyra::signature(format!(
            "{status} {}",
            body.lines().next().unwrap_or("no body")
        ));
    }
    assert_eq!(
        status,
        200,
        "request {request:?}\n{:?}",
        body.lines().next()
    );
}

#[ephyra::test]
fn tls_options_survive_the_bind_string(bytes: Vec<u8>) {
    let mut input = Input {
        bytes: &bytes,
        at: 0,
    };
    let cipher = [
        "ECDHE",
        "AESGCM",
        "+",
        ":",
        "!",
        "-",
        "@SECLEVEL=1",
        "HIGH",
        " ",
        "aNULL",
        ",",
    ];
    let suite = [
        "TLS_AES_256_GCM_SHA384",
        ":",
        "TLS_CHACHA20_POLY1305_SHA256",
    ];
    let path = [
        "/etc/ssl/",
        "cert",
        ".pem",
        " ",
        "+",
        "&",
        "#",
        "%",
        "=",
        "é",
        "?",
    ];
    let mut pick = |parts: &[&str], most: usize| -> String {
        (0..input.next() % (most + 1))
            .map(|_| parts[input.next() % parts.len()])
            .collect()
    };
    let values = [
        pick(&cipher, 6),
        pick(&suite, 3),
        format!("/c{}", pick(&path, 5)),
        format!("/k{}", pick(&path, 5)),
        format!("/a{}", pick(&path, 5)),
    ];
    let names = ["ssl_cipher_filter", "ssl_ciphersuites", "cert", "key", "ca"];
    let sent: Vec<String> = values.iter().map(|v| hex(v.as_bytes())).collect();
    let request = format!(
        "GET / HTTP/1.1\r\nHost: example.com\r\nX-Ssl: {}\r\nConnection: close\r\n\r\n",
        sent.join(".")
    );
    let (_, body) = status_and_body(&exchange(request.as_bytes(), &[]));
    let got: Vec<&str> = body.split('.').collect();
    for (index, name) in names.iter().enumerate() {
        if got.get(index).copied() != Some(sent[index].as_str()) {
            let bad: String = values[index]
                .chars()
                .filter(|c| " +&#%=?,é".contains(*c))
                .take(1)
                .collect();
            ephyra::signature(format!("{name} with {bad:?}"));
            panic!(
                "{name} = {:?} came back as {body:?} (sent {:?})",
                values[index], sent[index]
            );
        }
    }
}

#[ephyra::test]
fn app_header_values_cannot_add_response_lines(bytes: Vec<u8>) {
    let mut input = Input {
        bytes: &bytes,
        at: 0,
    };
    let key_parts = [
        "x", "-", "a", ":", " ", "\r", "\n", "\0", "\t", "\x7f", "é", "(", "\"",
    ];
    let value_parts = [
        "a",
        " ",
        "\r",
        "\n",
        "\r\n",
        "injected: 1",
        ":",
        "\0",
        "\x0b",
        "\x0c",
        "\u{85}",
        "\u{2028}",
        "\x7f",
        "\t",
        "\x1b",
    ];
    let mut key = String::from("x");
    for _ in 0..input.next() % 4 {
        key.push_str(key_parts[input.next() % key_parts.len()]);
    }
    let mut value = String::new();
    for _ in 0..input.next() % 6 {
        value.push_str(value_parts[input.next() % value_parts.len()]);
    }
    let kind = input.next() % 2;
    let request = format!(
        "GET / HTTP/1.1\r\nHost: example.com\r\nX-Hdr: {}.{}.{kind}\r\nConnection: close\r\n\r\n",
        hex(key.as_bytes()),
        hex(value.as_bytes())
    );
    let raw = exchange(request.as_bytes(), &[]);
    let text = show(&raw);
    let fail = |why: &str| -> ! {
        ephyra::signature(why.to_string());
        panic!("{why}: key {key:?} value {value:?} kind {kind}\nresponse {text:?}")
    };
    let mut rest = text.as_str();
    let mut finals = 0;
    while !rest.is_empty() {
        let Some((head, after)) = rest.split_once("\r\n\r\n") else {
            fail("unterminated head")
        };
        let mut lines = head.split("\r\n");
        let status = lines.next().unwrap_or("");
        let interim = status == "HTTP/1.1 103 Early Hints";
        if !interim && status != "HTTP/1.1 200 OK" {
            fail("unexpected status line");
        }
        for line in lines {
            if line.contains(['\r', '\n', '\0']) {
                fail("control character in a header line");
            }
            let name = line.split(':').next().unwrap_or("").to_lowercase();
            let known = !interim && (name == "connection" || name == "content-length");
            if name != key.to_lowercase() && !known {
                fail("header line the app did not ask for");
            }
            if line.to_lowercase().starts_with("injected") {
                fail("injected header");
            }
        }
        if interim {
            rest = after;
        } else {
            finals += 1;
            if after != "hi" {
                fail("body changed");
            }
            rest = "";
        }
    }
    if finals != 1 {
        fail("no final response");
    }
}

#[ephyra::test]
fn pipelined_requests_see_only_their_own_headers(bytes: Vec<u8>) {
    let mut input = Input {
        bytes: &bytes,
        at: 0,
    };
    let names = ["X-A", "X_A", "x-a", "X-B", "X_B"];
    let values = ["1", "2", "a b"];
    let mut stream = Vec::new();
    let mut wanted = Vec::new();
    for _ in 0..1 + input.next() % 4 {
        stream.extend(b"GET / HTTP/1.1\r\nHost: example.com\r\nX-Echo: 1\r\n");
        let mut dashed: Vec<(String, Vec<&str>)> = Vec::new();
        let mut underscored: Vec<(String, Vec<&str>)> = Vec::new();
        for _ in 0..input.next() % 5 {
            let name = names[input.next() % names.len()];
            let value = values[input.next() % values.len()];
            stream.extend(format!("{name}: {value}\r\n").bytes());
            let key = format!("HTTP_{}", name.to_uppercase().replace('-', "_"));
            let group = if name.contains('_') {
                &mut underscored
            } else {
                &mut dashed
            };
            match group.iter_mut().find(|(k, _)| *k == key) {
                Some((_, list)) => list.push(value),
                None => group.push((key, vec![value])),
            }
        }
        stream.extend(b"\r\n");
        for (key, list) in underscored {
            if !dashed.iter().any(|(k, _)| *k == key) {
                dashed.push((key, list));
            }
        }
        dashed.sort();
        let body: Vec<String> = dashed
            .iter()
            .map(|(k, v)| format!("{k}={}", v.join(", ")))
            .collect();
        wanted.push(body.join(";"));
    }
    let cuts = input.cuts(stream.len());
    for cuts in [&[][..], &cuts[..]] {
        let raw = exchange(&stream, cuts);
        let got: Vec<String> = parse(&raw, &[])
            .unwrap_or_else(|e| panic!("{e}: {:?}", show(&raw)))
            .into_iter()
            .map(|r| r.body)
            .collect();
        assert_eq!(got, wanted, "request {:?} cuts {cuts:?}", show(&stream));
    }
}

#[ephyra::test]
fn content_length_may_be_an_array_of_one_string(bytes: Vec<u8>) {
    let length = bytes.first().copied().unwrap_or(0) as usize;
    let request = format!(
        "GET / HTTP/1.1\r\nHost: example.com\r\nX-Len: {length}\r\nConnection: close\r\n\r\n"
    );
    let raw = exchange(request.as_bytes(), &[]);
    let (status, body) = status_and_body(&raw);
    assert_eq!(
        (status, body.lines().next().unwrap_or("")),
        (200, "x".repeat(length).as_str()),
        "request {request:?}"
    );
}
