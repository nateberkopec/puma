#![allow(dead_code)]

include!("support/common.rs");

fn statuses(stream: &[u8], cuts: &[usize]) -> Vec<u16> {
    let raw = exchange(stream, cuts);
    parse(&raw, &[])
        .map(|responses| responses.iter().map(|r| r.status).collect())
        .unwrap_or_default()
}

const HEAD: &str =
    "POST / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n";

#[ephyra::test]
fn chunk_data_must_end_with_crlf(bytes: Vec<u8>) {
    let mut input = Input {
        bytes: &bytes,
        at: 0,
    };
    let len = 1 + input.next() % 12;
    let bad = ["XY", "\rX", "X\n", "\n\r"][input.next() % 4];
    let stream = format!("{HEAD}{len:x}\r\n{}{bad}0\r\n\r\n", "a".repeat(len)).into_bytes();
    let cuts = input.cuts(stream.len());
    for cuts in [&[][..], &cuts[..]] {
        let got = statuses(&stream, cuts);
        assert_eq!(got, [400], "request {:?} cuts {cuts:?}", show(&stream));
    }
}

#[ephyra::test]
fn chunk_size_is_only_hex_digits(bytes: Vec<u8>) {
    let mut input = Input {
        bytes: &bytes,
        at: 0,
    };
    let junk = [" ", "\t", "\0", "\x0b", "\x0c", "\n", "\r"];
    let before = input.next() % 2 == 1;
    let extra = junk[input.next() % junk.len()];
    let size = if before {
        format!("{extra}1")
    } else {
        format!("1{extra}")
    };
    let stream = format!("{HEAD}{size}\r\na\r\n0\r\n\r\n").into_bytes();
    ephyra::signature(format!("{size:?}"));
    let got = statuses(&stream, &[]);
    assert_eq!(got, [400], "request {:?}", show(&stream));
}
