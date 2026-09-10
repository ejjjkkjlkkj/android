use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

pub const CONFIG_SCHEMA: u32 = 1;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct VmConfig {
    pub schema: u32,
    pub name: String,
    pub qemu_binary: String,
    pub iso_path: String,
    pub disk_path: String,
    pub memory_mib: u32,
    pub cpu_count: u32,
    pub qmp_port: u16,
    pub serial_log_path: String,
}

impl Default for VmConfig {
    fn default() -> Self {
        Self {
            schema: CONFIG_SCHEMA,
            name: "Accessible Android 17".to_owned(),
            qemu_binary: default_qemu_binary(),
            iso_path: String::new(),
            disk_path: String::new(),
            memory_mib: 4096,
            cpu_count: 4,
            qmp_port: 4444,
            serial_log_path: "accessible-qemu-serial.log".to_owned(),
        }
    }
}

impl VmConfig {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema != CONFIG_SCHEMA {
            return Err(format!(
                "Unsupported VM configuration schema {}. Expected {}.",
                self.schema, CONFIG_SCHEMA
            ));
        }
        if self.name.trim().is_empty() {
            return Err("Virtual machine name cannot be empty.".to_owned());
        }
        if self.qemu_binary.trim().is_empty() {
            return Err("QEMU executable cannot be empty.".to_owned());
        }
        if !(1024..=32768).contains(&self.memory_mib) {
            return Err("Memory must be between 1024 and 32768 MiB.".to_owned());
        }
        if !(1..=16).contains(&self.cpu_count) {
            return Err("Processor count must be between 1 and 16.".to_owned());
        }
        if self.qmp_port < 1024 {
            return Err("QMP port must be between 1024 and 65535.".to_owned());
        }
        if self.iso_path.trim().is_empty() && self.disk_path.trim().is_empty() {
            return Err("Provide an ISO path, a virtual disk path, or both.".to_owned());
        }
        if !self.iso_path.trim().is_empty() && !Path::new(self.iso_path.trim()).is_file() {
            return Err(format!("ISO not found: {}", self.iso_path.trim()));
        }
        if !self.disk_path.trim().is_empty() && !Path::new(self.disk_path.trim()).is_file() {
            return Err(format!("Virtual disk not found: {}", self.disk_path.trim()));
        }
        Ok(())
    }

    pub fn load(path: &Path) -> Result<Self, String> {
        let data = fs::read_to_string(path)
            .map_err(|error| format!("Cannot read configuration {}: {error}", path.display()))?;
        let config: Self = serde_json::from_str(&data)
            .map_err(|error| format!("Invalid configuration {}: {error}", path.display()))?;
        if config.schema != CONFIG_SCHEMA {
            return Err(format!(
                "Unsupported configuration schema {} in {}. Expected {}.",
                config.schema,
                path.display(),
                CONFIG_SCHEMA
            ));
        }
        Ok(config)
    }

    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                fs::create_dir_all(parent).map_err(|error| {
                    format!("Cannot create configuration directory {}: {error}", parent.display())
                })?;
            }
        }
        let data = serde_json::to_string_pretty(self)
            .map_err(|error| format!("Cannot serialize VM configuration: {error}"))?;
        fs::write(path, format!("{data}\n"))
            .map_err(|error| format!("Cannot write configuration {}: {error}", path.display()))
    }
}

fn default_qemu_binary() -> String {
    #[cfg(target_os = "windows")]
    {
        let candidates = [
            r"C:\Program Files\qemu\qemu-system-x86_64.exe",
            r"C:\Program Files (x86)\qemu\qemu-system-x86_64.exe",
        ];
        for candidate in candidates {
            if Path::new(candidate).is_file() {
                return candidate.to_owned();
            }
        }
        "qemu-system-x86_64.exe".to_owned()
    }

    #[cfg(not(target_os = "windows"))]
    {
        "qemu-system-x86_64".to_owned()
    }
}
