use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

const MAX_SERIAL_BYTES: u64 = 256 * 1024;

pub fn read_serial_tail(path: &str) -> Result<String, String> {
    let path = Path::new(path.trim());
    if path.as_os_str().is_empty() {
        return Err("Serial log path is empty.".to_owned());
    }

    let mut file = File::open(path)
        .map_err(|error| format!("Cannot open serial log {}: {error}", path.display()))?;
    let size = file
        .metadata()
        .map_err(|error| format!("Cannot inspect serial log {}: {error}", path.display()))?
        .len();

    let start = size.saturating_sub(MAX_SERIAL_BYTES);
    if start > 0 {
        file.seek(SeekFrom::Start(start))
            .map_err(|error| format!("Cannot seek serial log {}: {error}", path.display()))?;
    }

    let mut bytes = Vec::with_capacity((size - start).min(MAX_SERIAL_BYTES) as usize);
    file.read_to_end(&mut bytes)
        .map_err(|error| format!("Cannot read serial log {}: {error}", path.display()))?;

    // If the read starts in the middle of a UTF-8 sequence, drop the incomplete
    // prefix. QEMU serial output is normally ASCII/UTF-8, and lossy conversion
    // keeps diagnostics usable even when firmware emits arbitrary bytes.
    let mut text = String::from_utf8_lossy(&bytes).into_owned();
    if start > 0 {
        if let Some(newline) = text.find('\n') {
            text.drain(..=newline);
        }
    }

    if text.is_empty() {
        text.push_str("Serial log is currently empty.");
    }

    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn reads_serial_text() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("accessible-qemu-serial-{unique}.log"));
        fs::write(&path, "boot line 1\nACCESSIBLE_ANDROID_KERNEL_BOOT=PASS\n").unwrap();
        let text = read_serial_tail(path.to_str().unwrap()).unwrap();
        assert!(text.contains("ACCESSIBLE_ANDROID_KERNEL_BOOT=PASS"));
        let _ = fs::remove_file(path);
    }
}
