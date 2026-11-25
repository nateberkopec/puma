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
