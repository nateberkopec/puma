use std::process::Command;

#[ephyra::test]
fn working_directory_round_trips(bytes: Vec<u8>) {
    let alphabet = b"ab01-_ \\\"";
    let mut path = String::from("/");
    for byte in bytes.iter().take(32) {
        path.push(alphabet[*byte as usize % alphabet.len()] as char);
    }
    let result = Command::new("ruby")
        .arg(concat!(env!("CARGO_MANIFEST_DIR"), "/state.rb"))
        .arg(&path)
        .output()
        .expect("start ruby");
    assert!(
        result.status.success(),
        "{path:?}: {}",
        String::from_utf8_lossy(&result.stderr)
    );
}

#[ephyra::test]
fn control_token_round_trips(bytes: Vec<u8>) {
    let alphabet = b"0123456789abcdef.";
    let token: String = bytes
        .iter()
        .take(32)
        .map(|byte| alphabet[*byte as usize % alphabet.len()] as char)
        .collect();
    if token.is_empty() {
        return;
    }
    let result = Command::new("ruby")
        .arg(concat!(env!("CARGO_MANIFEST_DIR"), "/token.rb"))
        .arg(&token)
        .output()
        .expect("start ruby");
    assert!(
        result.status.success(),
        "{token:?}: {}",
        String::from_utf8_lossy(&result.stderr)
            .lines()
            .next()
            .unwrap_or("")
    );
}
