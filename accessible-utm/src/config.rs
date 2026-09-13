use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

pub const VM_CONFIG_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Architecture {
    X86_64,
    Aarch64,
    Riscv64,
}

impl Architecture {
    pub const ALL: [Self; 3] = [Self::X86_64, Self::Aarch64, Self::Riscv64];

    pub fn label(self) -> &'static str {
        match self {
            Self::X86_64 => "x86_64",
            Self::Aarch64 => "ARM64 (aarch64)",
            Self::Riscv64 => "RISC-V 64",
        }
    }

    pub fn cli_name(self) -> &'static str {
        match self {
            Self::X86_64 => "x86_64",
            Self::Aarch64 => "aarch64",
            Self::Riscv64 => "riscv64",
        }
    }

    pub fn from_cli(value: &str) -> Option<Self> {
        match value.to_ascii_lowercase().as_str() {
            "x86_64" | "x64" | "amd64" => Some(Self::X86_64),
            "aarch64" | "arm64" => Some(Self::Aarch64),
            "riscv64" | "risc-v64" | "riscv" => Some(Self::Riscv64),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum GuestProfile {
    AccessibleAndroid,
    Linux,
    Windows,
    Generic,
}

impl GuestProfile {
    pub const ALL: [Self; 4] = [
        Self::AccessibleAndroid,
        Self::Linux,
        Self::Windows,
        Self::Generic,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::AccessibleAndroid => "AccessibleAndroid",
            Self::Linux => "Linux",
            Self::Windows => "Windows",
            Self::Generic => "Generic",
        }
    }

    pub fn cli_name(self) -> &'static str {
        match self {
            Self::AccessibleAndroid => "accessible-android",
            Self::Linux => "linux",
            Self::Windows => "windows",
            Self::Generic => "generic",
        }
    }

    pub fn from_cli(value: &str) -> Option<Self> {
        match value.to_ascii_lowercase().as_str() {
            "accessible-android" | "android" => Some(Self::AccessibleAndroid),
            "linux" => Some(Self::Linux),
            "windows" => Some(Self::Windows),
            "generic" => Some(Self::Generic),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct VmConfig {
    pub schema_version: u32,
    pub name: String,
    pub profile: GuestProfile,
    pub architecture: Architecture,
    pub qemu_binary: String,
    pub iso_path: String,
    pub disk_path: String,
    pub firmware_path: String,
    pub memory_mib: u32,
    pub cpu_count: u32,
    pub qmp_port: u16,
}

fn application_directory() -> Option<PathBuf> {
    env::current_exe().ok()?.parent().map(Path::to_path_buf)
}

fn bundled_file(relative: &[&str]) -> Option<String> {
    let mut path = application_directory()?;
    for component in relative {
        path.push(component);
    }
    path.is_file().then(|| path.to_string_lossy().into_owned())
}

fn bundled_x86_firmware() -> Option<String> {
    for relative in [
        &["qemu", "share", "edk2-x86_64-code.fd"][..],
        &["qemu", "edk2-x86_64-code.fd"][..],
        &["qemu", "share", "edk2-i386-code.fd"][..],
    ] {
        if let Some(path) = bundled_file(relative) {
            return Some(path);
        }
    }
    None
}

impl Default for VmConfig {
    fn default() -> Self {
        let disk_path = bundled_file(&["images", "AccessibleAndroid.qcow2"])
            .or_else(|| bundled_file(&["images", "AccessibleAndroid.img"]))
            .unwrap_or_default();
        let iso_path = if disk_path.is_empty() {
            bundled_file(&["images", "AccessibleAndroid.iso"]).unwrap_or_default()
        } else {
            String::new()
        };

        Self {
            schema_version: VM_CONFIG_SCHEMA_VERSION,
            name: "AccessibleAndroid".to_owned(),
            profile: GuestProfile::AccessibleAndroid,
            architecture: Architecture::X86_64,
            qemu_binary: String::new(),
            iso_path,
            disk_path,
            firmware_path: bundled_x86_firmware().unwrap_or_default(),
            memory_mib: 8192,
            cpu_count: 6,
            qmp_port: 4444,
        }
    }
}

impl VmConfig {
    pub fn normalize(&mut self) {
        self.schema_version = VM_CONFIG_SCHEMA_VERSION;
        self.memory_mib = self.memory_mib.clamp(1024, 65536);
        self.cpu_count = self.cpu_count.clamp(1, 32);
        if self.qmp_port == 0 {
            self.qmp_port = 4444;
        }
        if self.name.trim().is_empty() {
            self.name = self.profile.label().to_owned();
        }
    }

    pub fn to_json_pretty(&self) -> Result<String, String> {
        serde_json::to_string_pretty(self)
            .map_err(|error| format!("Cannot serialize VM configuration: {error}"))
    }

    pub fn from_json(text: &str) -> Result<Self, String> {
        let mut config: Self = serde_json::from_str(text)
            .map_err(|error| format!("Cannot parse VM configuration: {error}"))?;
        if config.schema_version > VM_CONFIG_SCHEMA_VERSION {
            return Err(format!(
                "VM configuration schema {} is newer than supported schema {}.",
                config.schema_version, VM_CONFIG_SCHEMA_VERSION
            ));
        }
        config.normalize();
        Ok(config)
    }

    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                fs::create_dir_all(parent).map_err(|error| {
                    format!(
                        "Cannot create VM configuration directory '{}': {error}",
                        parent.display()
                    )
                })?;
            }
        }

        let json = self.to_json_pretty()?;
        let temporary = path.with_extension("json.tmp");
        fs::write(&temporary, json).map_err(|error| {
            format!(
                "Cannot write temporary VM configuration '{}': {error}",
                temporary.display()
            )
        })?;

        if path.exists() {
            fs::remove_file(path).map_err(|error| {
                format!(
                    "Cannot replace existing VM configuration '{}': {error}",
                    path.display()
                )
            })?;
        }

        fs::rename(&temporary, path).map_err(|error| {
            format!(
                "Cannot commit VM configuration '{}': {error}",
                path.display()
            )
        })?;
        Ok(())
    }

    pub fn load(path: &Path) -> Result<Self, String> {
        let text = fs::read_to_string(path).map_err(|error| {
            format!(
                "Cannot read VM configuration '{}': {error}",
                path.display()
            )
        })?;
        Self::from_json(&text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn vm_configuration_json_round_trip_preserves_android_profile() {
        let source = VmConfig {
            disk_path: "AccessibleAndroid.qcow2".to_owned(),
            iso_path: "AccessibleAndroid.iso".to_owned(),
            ..VmConfig::default()
        };
        let json = source.to_json_pretty().unwrap();
        let restored = VmConfig::from_json(&json).unwrap();
        assert_eq!(restored.schema_version, VM_CONFIG_SCHEMA_VERSION);
        assert_eq!(restored.profile, GuestProfile::AccessibleAndroid);
        assert_eq!(restored.architecture, Architecture::X86_64);
        assert_eq!(restored.disk_path, "AccessibleAndroid.qcow2");
        assert_eq!(restored.iso_path, "AccessibleAndroid.iso");
        assert_eq!(restored.memory_mib, 8192);
        assert_eq!(restored.cpu_count, 6);
    }

    #[test]
    fn normalization_repairs_invalid_resource_values() {
        let mut config = VmConfig {
            name: String::new(),
            memory_mib: 1,
            cpu_count: 99,
            qmp_port: 0,
            ..VmConfig::default()
        };
        config.normalize();
        assert_eq!(config.name, "AccessibleAndroid");
        assert_eq!(config.memory_mib, 1024);
        assert_eq!(config.cpu_count, 32);
        assert_eq!(config.qmp_port, 4444);
    }

    #[test]
    fn rejects_future_configuration_schema() {
        let json = r#"{
            "schema_version": 999,
            "name": "Future VM"
        }"#;
        assert!(VmConfig::from_json(json).is_err());
    }

    #[test]
    fn save_can_replace_existing_configuration() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "accessible-utm-config-{}-{nonce}.json",
            std::process::id()
        ));

        let mut first = VmConfig::default();
        first.name = "First".to_owned();
        first.save(&path).unwrap();

        let mut second = VmConfig::default();
        second.name = "Second".to_owned();
        second.save(&path).unwrap();

        let restored = VmConfig::load(&path).unwrap();
        assert_eq!(restored.name, "Second");
        let _ = fs::remove_file(path);
    }
}
