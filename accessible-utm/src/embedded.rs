use std::env;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::OnceLock;

const PAYLOAD_MAGIC: &[u8; 16] = b"AUTM_PAYLOAD_V1!";
const PAYLOAD_TRAILER_SIZE: u64 = 16 + 8 + 4 + 8;
const MAX_PATH_BYTES: u32 = 32 * 1024;

static RUNTIME_ROOT: OnceLock<PathBuf> = OnceLock::new();

#[derive(Debug, Clone, Copy)]
struct PayloadDescriptor {
    start: u64,
    entries: u32,
    length: u64,
    executable_length: u64,
}

impl PayloadDescriptor {
    fn key(self) -> String {
        format!(
            "{:016x}-{:016x}-{:08x}-{:016x}",
            self.start, self.length, self.entries, self.executable_length
        )
    }

    fn end(self) -> Result<u64, String> {
        self.start
            .checked_add(self.length)
            .ok_or_else(|| "Embedded payload length overflow.".to_owned())
    }
}

fn read_u32(reader: &mut File) -> Result<u32, String> {
    let mut bytes = [0u8; 4];
    reader
        .read_exact(&mut bytes)
        .map_err(|error| format!("Cannot read embedded payload u32: {error}"))?;
    Ok(u32::from_le_bytes(bytes))
}

fn read_u64(reader: &mut File) -> Result<u64, String> {
    let mut bytes = [0u8; 8];
    reader
        .read_exact(&mut bytes)
        .map_err(|error| format!("Cannot read embedded payload u64: {error}"))?;
    Ok(u64::from_le_bytes(bytes))
}

fn payload_descriptor(executable: &mut File) -> Result<Option<PayloadDescriptor>, String> {
    let executable_length = executable
        .metadata()
        .map_err(|error| format!("Cannot inspect executable metadata: {error}"))?
        .len();
    if executable_length < PAYLOAD_TRAILER_SIZE {
        return Ok(None);
    }

    executable
        .seek(SeekFrom::End(-(PAYLOAD_TRAILER_SIZE as i64)))
        .map_err(|error| format!("Cannot seek to embedded payload trailer: {error}"))?;

    let mut magic = [0u8; 16];
    executable
        .read_exact(&mut magic)
        .map_err(|error| format!("Cannot read embedded payload marker: {error}"))?;
    if &magic != PAYLOAD_MAGIC {
        return Ok(None);
    }

    let start = read_u64(executable)?;
    let entries = read_u32(executable)?;
    let length = read_u64(executable)?;
    if entries == 0 {
        return Err("Embedded payload contains no files.".to_owned());
    }

    let descriptor = PayloadDescriptor {
        start,
        entries,
        length,
        executable_length,
    };
    let expected_trailer_start = executable_length
        .checked_sub(PAYLOAD_TRAILER_SIZE)
        .ok_or_else(|| "Embedded payload trailer underflow.".to_owned())?;
    if descriptor.end()? != expected_trailer_start {
        return Err(format!(
            "Embedded payload boundaries are invalid: start={}, length={}, trailer={expected_trailer_start}.",
            descriptor.start, descriptor.length
        ));
    }
    Ok(Some(descriptor))
}

fn safe_relative_path(text: &str) -> Result<PathBuf, String> {
    if text.is_empty() {
        return Err("Embedded payload contains an empty path.".to_owned());
    }
    let path = Path::new(text);
    if path.is_absolute() {
        return Err(format!("Embedded payload contains an absolute path: {text}"));
    }

    let mut clean = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(value) => clean.push(value),
            _ => {
                return Err(format!(
                    "Embedded payload contains an unsafe path component: {text}"
                ));
            }
        }
    }
    if clean.as_os_str().is_empty() {
        return Err(format!("Embedded payload path is invalid: {text}"));
    }
    Ok(clean)
}

fn cache_root() -> PathBuf {
    let base = env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(env::temp_dir);
    base.join("AccessibleUTM")
}

fn runtime_is_complete(root: &Path) -> bool {
    [
        "qemu/qemu-system-x86_64.exe",
        "qemu/qemu-system-aarch64.exe",
        "qemu/qemu-system-riscv64.exe",
        "qemu/qemu-img.exe",
    ]
    .iter()
    .all(|relative| root.join(relative).is_file())
        && root.join(".payload-complete").is_file()
}

fn copy_exact_bytes(source: &mut File, destination: &mut File, mut remaining: u64) -> Result<(), String> {
    let mut buffer = vec![0u8; 1024 * 1024];
    while remaining > 0 {
        let wanted = usize::try_from(remaining.min(buffer.len() as u64))
            .map_err(|_| "Embedded payload chunk length overflow.".to_owned())?;
        source
            .read_exact(&mut buffer[..wanted])
            .map_err(|error| format!("Cannot read embedded payload file bytes: {error}"))?;
        destination
            .write_all(&buffer[..wanted])
            .map_err(|error| format!("Cannot write extracted payload file: {error}"))?;
        remaining -= wanted as u64;
    }
    destination
        .flush()
        .map_err(|error| format!("Cannot flush extracted payload file: {error}"))?;
    Ok(())
}

fn extract_payload(
    executable: &mut File,
    descriptor: PayloadDescriptor,
    destination: &Path,
) -> Result<(), String> {
    executable
        .seek(SeekFrom::Start(descriptor.start))
        .map_err(|error| format!("Cannot seek to embedded payload: {error}"))?;
    let payload_end = descriptor.end()?;

    for _ in 0..descriptor.entries {
        let path_length = read_u32(executable)?;
        let data_length = read_u64(executable)?;
        if path_length == 0 || path_length > MAX_PATH_BYTES {
            return Err(format!(
                "Embedded payload path length is invalid: {path_length}."
            ));
        }

        let mut path_bytes = vec![0u8; path_length as usize];
        executable
            .read_exact(&mut path_bytes)
            .map_err(|error| format!("Cannot read embedded payload path: {error}"))?;
        let path_text = std::str::from_utf8(&path_bytes)
            .map_err(|error| format!("Embedded payload path is not UTF-8: {error}"))?;
        let relative = safe_relative_path(path_text)?;

        let current = executable
            .stream_position()
            .map_err(|error| format!("Cannot query embedded payload position: {error}"))?;
        let file_end = current
            .checked_add(data_length)
            .ok_or_else(|| format!("Embedded payload file length overflow: {path_text}"))?;
        if file_end > payload_end {
            return Err(format!(
                "Embedded payload file exceeds payload boundary: {path_text}"
            ));
        }

        let target = destination.join(relative);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "Cannot create embedded runtime directory '{}': {error}",
                    parent.display()
                )
            })?;
        }
        let mut output = File::create(&target).map_err(|error| {
            format!(
                "Cannot create extracted runtime file '{}': {error}",
                target.display()
            )
        })?;
        copy_exact_bytes(executable, &mut output, data_length)?;
    }

    let final_position = executable
        .stream_position()
        .map_err(|error| format!("Cannot query final embedded payload position: {error}"))?;
    if final_position != payload_end {
        return Err(format!(
            "Embedded payload entry table did not consume the payload exactly: {final_position} != {payload_end}."
        ));
    }
    Ok(())
}

#[cfg(target_os = "windows")]
pub fn prepare_runtime() -> Result<Option<PathBuf>, String> {
    if let Some(root) = RUNTIME_ROOT.get() {
        return Ok(Some(root.clone()));
    }

    let executable_path = env::current_exe()
        .map_err(|error| format!("Cannot locate AccessibleUTM executable: {error}"))?;
    let mut executable = File::open(&executable_path).map_err(|error| {
        format!(
            "Cannot open AccessibleUTM executable '{}': {error}",
            executable_path.display()
        )
    })?;
    let Some(descriptor) = payload_descriptor(&mut executable)? else {
        return Ok(None);
    };

    let runtime = cache_root().join("runtime").join(descriptor.key());
    if runtime_is_complete(&runtime) {
        let _ = RUNTIME_ROOT.set(runtime.clone());
        return Ok(Some(runtime));
    }

    if runtime.exists() {
        fs::remove_dir_all(&runtime).map_err(|error| {
            format!(
                "Cannot remove incomplete embedded runtime '{}': {error}",
                runtime.display()
            )
        })?;
    }
    if let Some(parent) = runtime.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!(
                "Cannot create AccessibleUTM runtime cache '{}': {error}",
                parent.display()
            )
        })?;
    }

    let staging = runtime.with_extension(format!("tmp-{}", std::process::id()));
    fs::remove_dir_all(&staging).ok();
    fs::create_dir_all(&staging).map_err(|error| {
        format!(
            "Cannot create embedded runtime staging directory '{}': {error}",
            staging.display()
        )
    })?;

    let extraction_result = (|| {
        extract_payload(&mut executable, descriptor, &staging)?;
        if ![
            "qemu/qemu-system-x86_64.exe",
            "qemu/qemu-system-aarch64.exe",
            "qemu/qemu-system-riscv64.exe",
            "qemu/qemu-img.exe",
        ]
        .iter()
        .all(|relative| staging.join(relative).is_file())
        {
            return Err("Embedded runtime is incomplete after extraction.".to_owned());
        }
        fs::write(staging.join(".payload-complete"), descriptor.key()).map_err(|error| {
            format!("Cannot write embedded runtime completion marker: {error}")
        })?;
        Ok::<(), String>(())
    })();

    if let Err(error) = extraction_result {
        fs::remove_dir_all(&staging).ok();
        return Err(error);
    }

    match fs::rename(&staging, &runtime) {
        Ok(()) => {}
        Err(error) if runtime_is_complete(&runtime) => {
            fs::remove_dir_all(&staging).ok();
            let _ = error;
        }
        Err(error) => {
            fs::remove_dir_all(&staging).ok();
            return Err(format!(
                "Cannot publish embedded runtime '{}': {error}",
                runtime.display()
            ));
        }
    }

    if !runtime_is_complete(&runtime) {
        return Err("Embedded runtime validation failed after extraction.".to_owned());
    }
    let _ = RUNTIME_ROOT.set(runtime.clone());
    Ok(Some(runtime))
}

#[cfg(not(target_os = "windows"))]
pub fn prepare_runtime() -> Result<Option<PathBuf>, String> {
    Ok(None)
}

pub fn runtime_root() -> Option<PathBuf> {
    RUNTIME_ROOT.get().cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_parent_and_absolute_payload_paths() {
        assert!(safe_relative_path("../escape.txt").is_err());
        assert!(safe_relative_path("/absolute.txt").is_err());
        assert!(safe_relative_path("qemu/../escape.txt").is_err());
        assert!(safe_relative_path("qemu/qemu-system-x86_64.exe").is_ok());
    }

    #[test]
    fn payload_magic_is_fixed_width() {
        assert_eq!(PAYLOAD_MAGIC.len(), 16);
        assert_eq!(PAYLOAD_TRAILER_SIZE, 36);
    }
}
