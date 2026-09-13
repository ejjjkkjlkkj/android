use crate::config::{Architecture, GuestProfile, VmConfig};
use std::env;
use std::path::Path;

pub const ANDROID_OS_DISK_ID: &str = "osdisk";
pub const ANDROID_OS_DISK_PCI_ADDR: &str = "0x6";
pub const ANDROID_RNG_PCI_ADDR: &str = "0x7";
pub const ANDROID_NET_PCI_ADDR: &str = "0x8";

pub fn qemu_program_name(architecture: Architecture) -> &'static str {
    match architecture {
        Architecture::X86_64 => "qemu-system-x86_64",
        Architecture::Aarch64 => "qemu-system-aarch64",
        Architecture::Riscv64 => "qemu-system-riscv64",
    }
}

#[cfg(target_os = "windows")]
fn bundled_qemu_binary(exe: &str) -> Option<String> {
    let current_exe = env::current_exe().ok()?;
    let app_dir = current_exe.parent()?;
    let candidate = app_dir.join("qemu").join(exe);
    candidate.is_file().then(|| candidate.to_string_lossy().into_owned())
}

pub fn default_qemu_binary(architecture: Architecture) -> String {
    let program = qemu_program_name(architecture);

    #[cfg(target_os = "windows")]
    {
        let exe = format!("{program}.exe");
        if let Some(candidate) = bundled_qemu_binary(&exe) {
            return candidate;
        }
        let candidates = [
            format!(r"C:\Program Files\qemu\{exe}"),
            format!(r"C:\Program Files (x86)\qemu\{exe}"),
        ];
        for candidate in candidates {
            if Path::new(&candidate).is_file() {
                return candidate;
            }
        }
        exe
    }

    #[cfg(not(target_os = "windows"))]
    {
        program.to_owned()
    }
}

pub fn accelerator(architecture: Architecture) -> &'static str {
    match architecture {
        Architecture::X86_64 => {
            #[cfg(target_os = "windows")]
            {
                "whpx:tcg"
            }
            #[cfg(target_os = "linux")]
            {
                "kvm:tcg"
            }
            #[cfg(target_os = "macos")]
            {
                "hvf:tcg"
            }
            #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
            {
                "tcg"
            }
        }
        Architecture::Aarch64 | Architecture::Riscv64 => "tcg",
    }
}

pub fn machine(architecture: Architecture) -> &'static str {
    match architecture {
        Architecture::X86_64 => "q35",
        Architecture::Aarch64 | Architecture::Riscv64 => "virt",
    }
}

pub fn host_audio_driver() -> &'static str {
    #[cfg(target_os = "windows")]
    {
        "dsound"
    }
    #[cfg(target_os = "linux")]
    {
        "pa"
    }
    #[cfg(target_os = "macos")]
    {
        "coreaudio"
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
    {
        "sdl"
    }
}

pub fn disk_format(path: &str) -> Result<&'static str, String> {
    let extension = Path::new(path)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    match extension.as_str() {
        "qcow2" | "qcow" => Ok("qcow2"),
        "raw" | "img" => Ok("raw"),
        "vdi" => Ok("vdi"),
        "vmdk" => Ok("vmdk"),
        "vhd" | "vpc" => Ok("vpc"),
        "vhdx" => Ok("vhdx"),
        _ => Err(format!(
            "Unsupported virtual disk format for '{path}'. Use RAW/IMG, QCOW2, VDI, VMDK, VHD or VHDX."
        )),
    }
}

pub fn quote_for_display(value: &str) -> String {
    if value.is_empty() || value.chars().any(char::is_whitespace) {
        format!("\"{}\"", value.replace('"', "\\\""))
    } else {
        value.to_owned()
    }
}

pub fn validate_media(config: &VmConfig) -> Result<(), String> {
    if config.iso_path.trim().is_empty() && config.disk_path.trim().is_empty() {
        return Err("Provide an ISO path, a virtual disk path, or both.".to_owned());
    }
    if !config.iso_path.trim().is_empty() && !Path::new(config.iso_path.trim()).is_file() {
        return Err(format!("ISO not found: {}", config.iso_path.trim()));
    }
    if !config.disk_path.trim().is_empty() && !Path::new(config.disk_path.trim()).is_file() {
        return Err(format!("Virtual disk not found: {}", config.disk_path.trim()));
    }
    if !config.firmware_path.trim().is_empty()
        && !Path::new(config.firmware_path.trim()).is_file()
    {
        return Err(format!("Firmware not found: {}", config.firmware_path.trim()));
    }
    Ok(())
}

fn add_accessible_android_devices(args: &mut Vec<String>) {
    args.extend([
        "-device".to_owned(),
        "virtio-vga,id=android-gpu".to_owned(),
        "-device".to_owned(),
        "qemu-xhci,id=xhci".to_owned(),
        "-device".to_owned(),
        "usb-kbd,bus=xhci.0,id=android-keyboard".to_owned(),
        "-device".to_owned(),
        "usb-tablet,bus=xhci.0,id=android-tablet".to_owned(),
        "-audiodev".to_owned(),
        format!("{},id=android-audio", host_audio_driver()),
        "-device".to_owned(),
        "virtio-sound-pci,audiodev=android-audio,streams=2,id=android-sound".to_owned(),
    ]);
}

pub fn build_args(config: &VmConfig) -> Result<Vec<String>, String> {
    let mut args = vec![
        "-name".to_owned(),
        config.name.clone(),
        "-machine".to_owned(),
        format!("{},accel={}", machine(config.architecture), accelerator(config.architecture)),
        "-m".to_owned(),
        config.memory_mib.clamp(1024, 65536).to_string(),
        "-smp".to_owned(),
        config.cpu_count.clamp(1, 32).to_string(),
        "-qmp".to_owned(),
        format!("tcp:127.0.0.1:{},server=on,wait=off", config.qmp_port),
        "-monitor".to_owned(),
        "none".to_owned(),
    ];

    if !config.firmware_path.trim().is_empty() {
        args.push("-bios".to_owned());
        args.push(config.firmware_path.trim().to_owned());
    }

    if !config.disk_path.trim().is_empty() {
        let format = disk_format(config.disk_path.trim())?;
        args.push("-drive".to_owned());
        args.push(format!(
            "if=none,id={ANDROID_OS_DISK_ID},file={},format={format},cache=writeback",
            config.disk_path.trim()
        ));
        args.push("-device".to_owned());

        if config.profile == GuestProfile::AccessibleAndroid
            && config.architecture == Architecture::X86_64
        {
            args.push(format!(
                "virtio-blk-pci,drive={ANDROID_OS_DISK_ID},bus=pcie.0,addr={ANDROID_OS_DISK_PCI_ADDR},bootindex=1"
            ));
        } else {
            args.push(format!(
                "virtio-blk-pci,drive={ANDROID_OS_DISK_ID},bootindex=1"
            ));
        }
    }

    if config.profile == GuestProfile::AccessibleAndroid
        && config.architecture == Architecture::X86_64
    {
        args.extend([
            "-device".to_owned(),
            format!("virtio-rng-pci,bus=pcie.0,addr={ANDROID_RNG_PCI_ADDR}"),
            "-netdev".to_owned(),
            "user,id=net0".to_owned(),
            "-device".to_owned(),
            format!("virtio-net-pci,netdev=net0,bus=pcie.0,addr={ANDROID_NET_PCI_ADDR}"),
        ]);
        add_accessible_android_devices(&mut args);
    } else {
        args.extend([
            "-device".to_owned(),
            "virtio-rng-pci".to_owned(),
            "-netdev".to_owned(),
            "user,id=net0".to_owned(),
            "-device".to_owned(),
            "virtio-net-pci,netdev=net0".to_owned(),
        ]);
    }

    if !config.iso_path.trim().is_empty() {
        args.push("-cdrom".to_owned());
        args.push(config.iso_path.trim().to_owned());
        args.push("-boot".to_owned());
        args.push("menu=on,order=d".to_owned());
    } else if !config.disk_path.trim().is_empty() {
        args.push("-boot".to_owned());
        args.push("menu=on,order=c".to_owned());
    }

    Ok(args)
}

pub fn printable_command(config: &VmConfig) -> Result<String, String> {
    let program = if config.qemu_binary.trim().is_empty() {
        default_qemu_binary(config.architecture)
    } else {
        config.qemu_binary.trim().to_owned()
    };
    let args = build_args(config)?;
    let mut parts = Vec::with_capacity(args.len() + 1);
    parts.push(quote_for_display(&program));
    parts.extend(args.iter().map(|arg| quote_for_display(arg)));
    Ok(parts.join(" "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_common_utm_disk_formats() {
        assert_eq!(disk_format("disk.qcow2").unwrap(), "qcow2");
        assert_eq!(disk_format("disk.raw").unwrap(), "raw");
        assert_eq!(disk_format("disk.img").unwrap(), "raw");
        assert_eq!(disk_format("disk.vdi").unwrap(), "vdi");
        assert_eq!(disk_format("disk.vmdk").unwrap(), "vmdk");
        assert_eq!(disk_format("disk.vhd").unwrap(), "vpc");
        assert_eq!(disk_format("disk.vhdx").unwrap(), "vhdx");
        assert!(disk_format("disk.iso").is_err());
    }

    #[test]
    fn preserves_accessible_android_x86_disk_contract() {
        let config = VmConfig {
            disk_path: "AccessibleAndroid.qcow2".to_owned(),
            ..VmConfig::default()
        };
        let args = build_args(&config).unwrap();
        assert!(args.iter().any(|arg| {
            arg == "virtio-blk-pci,drive=osdisk,bus=pcie.0,addr=0x6,bootindex=1"
        }));
        assert!(args
            .iter()
            .any(|arg| arg == "virtio-rng-pci,bus=pcie.0,addr=0x7"));
        assert!(args
            .iter()
            .any(|arg| arg == "virtio-net-pci,netdev=net0,bus=pcie.0,addr=0x8"));
    }

    #[test]
    fn accessible_android_has_graphics_audio_and_absolute_input() {
        let config = VmConfig {
            disk_path: "AccessibleAndroid.qcow2".to_owned(),
            ..VmConfig::default()
        };
        let args = build_args(&config).unwrap();
        assert!(args.iter().any(|arg| arg == "virtio-vga,id=android-gpu"));
        assert!(args.iter().any(|arg| arg == "qemu-xhci,id=xhci"));
        assert!(args
            .iter()
            .any(|arg| arg == "usb-kbd,bus=xhci.0,id=android-keyboard"));
        assert!(args
            .iter()
            .any(|arg| arg == "usb-tablet,bus=xhci.0,id=android-tablet"));
        assert!(args
            .iter()
            .any(|arg| arg == &format!("{},id=android-audio", host_audio_driver())));
        assert!(args.iter().any(|arg| {
            arg == "virtio-sound-pci,audiodev=android-audio,streams=2,id=android-sound"
        }));
        assert!(!args.iter().any(|arg| arg == "-audio"));
    }

    #[test]
    fn supports_arm64_and_riscv64_qemu_programs() {
        assert_eq!(qemu_program_name(Architecture::Aarch64), "qemu-system-aarch64");
        assert_eq!(qemu_program_name(Architecture::Riscv64), "qemu-system-riscv64");
        assert_eq!(machine(Architecture::Aarch64), "virt");
        assert_eq!(machine(Architecture::Riscv64), "virt");
    }
}
