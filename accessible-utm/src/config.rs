use serde::{Deserialize, Serialize};

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
pub struct VmConfig {
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

impl Default for VmConfig {
    fn default() -> Self {
        Self {
            name: "AccessibleAndroid".to_owned(),
            profile: GuestProfile::AccessibleAndroid,
            architecture: Architecture::X86_64,
            qemu_binary: String::new(),
            iso_path: String::new(),
            disk_path: String::new(),
            firmware_path: String::new(),
            memory_mib: 8192,
            cpu_count: 6,
            qmp_port: 4444,
        }
    }
}
