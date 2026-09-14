use crate::config::{bundled_firmware, Architecture, GuestProfile, VmConfig};
use crate::embedded;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

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
    if let Some(runtime_root) = embedded::runtime_root() {
        let candidate = runtime_root.join("qemu").join(exe);
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }

    let current_exe = env::current_exe().ok()?;
    let app_dir = current_exe.parent()?;
    let candidate = app_dir.join("qemu").join(exe);
    candidate
        .is_file()
        .then(|| candidate.to_string_lossy().into_owned())
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

fn escape_qemu_keyval_path(path: &str) -> String {
    path.replace(',', ",,")
}

fn riscv_vars_firmware(code_path: &str) -> Option<PathBuf> {
    let code = Path::new(code_path);
    let file_name = code.file_name()?.to_str()?;
    let prefix = file_name.strip_suffix("-code.fd")?;
    let vars = code.with_file_name(format!("{prefix}-vars.fd"));
    vars.is_file().then_some(vars)
}

fn safe_vm_file_component(name: &str) -> String {
    let mut value = String::with_capacity(name.len());
    for character in name.chars() {
        if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
            value.push(character);
        } else {
            value.push('_');
        }
    }
    let value = value.trim_matches('.').trim_matches('_');
    if value.is_empty() {
        "vm".to_owned()
    } else {
        value.to_owned()
    }
}

fn user_nvram_directory() -> PathBuf {
    #[cfg(target_os = "windows")]
    if let Some(local_app_data) = env::var_os("LOCALAPPDATA") {
        return PathBuf::from(local_app_data)
            .join("AccessibleUTM")
            .join("nvram");
    }

    if let Some(xdg_data_home) = env::var_os("XDG_DATA_HOME") {
        return PathBuf::from(xdg_data_home)
            .join("AccessibleUTM")
            .join("nvram");
    }
    if let Some(home) = env::var_os("HOME") {
        return PathBuf::from(home)
            .join(".local")
            .join("share")
            .join("AccessibleUTM")
            .join("nvram");
    }
    env::temp_dir().join("AccessibleUTM").join("nvram")
}

fn private_riscv_vars_path(config: &VmConfig, template: &Path) -> PathBuf {
    let template_name = template
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("edk2-riscv-vars.fd");

    let disk = config.disk_path.trim();
    if !disk.is_empty() {
        let disk_path = Path::new(disk);
        let stem = disk_path
            .file_stem()
            .and_then(|name| name.to_str())
            .map(safe_vm_file_component)
            .unwrap_or_else(|| safe_vm_file_component(&config.name));
        let file_name = format!("{stem}-{template_name}");
        if let Some(parent) = disk_path.parent()
            && !parent.as_os_str().is_empty()
        {
            return parent.join(file_name);
        }
        return user_nvram_directory().join(file_name);
    }

    user_nvram_directory().join(format!(
        "{}-{template_name}",
        safe_vm_file_component(&config.name)
    ))
}

fn private_riscv_vars_firmware(config: &VmConfig, code_path: &str) -> Result<Option<String>, String> {
    let Some(template) = riscv_vars_firmware(code_path) else {
        return Ok(None);
    };
    let destination = private_riscv_vars_path(config, &template);

    if !destination.is_file() {
        if let Some(parent) = destination.parent()
            && !parent.as_os_str().is_empty()
        {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "Cannot create per-VM RISC-V NVRAM directory '{}': {error}",
                    parent.display()
                )
            })?;
        }
        fs::copy(&template, &destination).map_err(|error| {
            format!(
                "Cannot create per-VM RISC-V NVRAM '{}' from template '{}': {error}",
                destination.display(),
                template.display()
            )
        })?;
    }

    Ok(Some(destination.to_string_lossy().into_owned()))
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
        return Err(format!(
            "Virtual disk not found: {}",
            config.disk_path.trim()
        ));
    }
    if !config.firmware_path.trim().is_empty() && !Path::new(config.firmware_path.trim()).is_file()
    {
        return Err(format!(
            "Firmware not found: {}",
            config.firmware_path.trim()
        ));
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
    let firmware = if config.firmware_path.trim().is_empty() {
        bundled_firmware(config.architecture)
    } else {
        Some(config.firmware_path.trim().to_owned())
    };

    let mut machine_arg = format!(
        "{},accel={}",
        machine(config.architecture),
        accelerator(config.architecture)
    );
    let mut firmware_args = Vec::new();

    if let Some(firmware_path) = firmware.as_deref() {
        if config.architecture == Architecture::Riscv64 {
            machine_arg.push_str(",pflash0=pflash0");
            firmware_args.extend([
                "-blockdev".to_owned(),
                format!(
                    "node-name=pflash0,driver=file,read-only=on,filename={}",
                    escape_qemu_keyval_path(firmware_path)
                ),
            ]);

            if let Some(vars_path) = private_riscv_vars_firmware(config, firmware_path)? {
                machine_arg.push_str(",pflash1=pflash1");
                firmware_args.extend([
                    "-blockdev".to_owned(),
                    format!(
                        "node-name=pflash1,driver=file,filename={}",
                        escape_qemu_keyval_path(&vars_path)
                    ),
                ]);
            }
        } else {
            firmware_args.extend(["-bios".to_owned(), firmware_path.to_owned()]);
        }
    }

    let mut args = vec![
        "-name".to_owned(),
        config.name.clone(),
        "-machine".to_owned(),
        machine_arg,
        "-m".to_owned(),
        config.memory_mib.clamp(1024, 65536).to_string(),
        "-smp".to_owned(),
        config.cpu_count.clamp(1, 32).to_string(),
        "-qmp".to_owned(),
        format!("tcp:127.0.0.1:{},server=on,wait=off", config.qmp_port),
        "-monitor".to_owned(),
        "none".to_owned(),
    ];
    args.extend(firmware_args);

    if !config.disk_path.trim().is_empty() {
        let format = disk_format(config.disk_path.trim())?;
        args.push("-drive".to_owned());
        args.push(format!(
            "if=none,id={ANDROID_OS_DISK_ID},file={},format={format},cache=writeback",
            escape_qemu_keyval_path(config.disk_path.trim())
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
    use std::time::{SystemTime, UNIX_EPOCH};

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
    fn disk_path_commas_remain_part_of_the_filename() {
        let config = VmConfig {
            disk_path: "C:/VMs/Android, personal/disk.qcow2".to_owned(),
            ..VmConfig::default()
        };
        let args = build_args(&config).unwrap();
        let drive = args.windows(2).find(|pair| pair[0] == "-drive").unwrap();
        assert_eq!(
            drive[1],
            "if=none,id=osdisk,file=C:/VMs/Android,, personal/disk.qcow2,format=qcow2,cache=writeback"
        );
    }

    #[test]
    fn explicit_firmware_override_is_preserved() {
        let config = VmConfig {
            firmware_path: "custom-uefi.fd".to_owned(),
            ..VmConfig::default()
        };
        let args = build_args(&config).unwrap();
        let firmware = args.windows(2).find(|pair| pair[0] == "-bios").unwrap();
        assert_eq!(firmware[1], "custom-uefi.fd");
    }

    #[test]
    fn riscv_uefi_uses_pflash_instead_of_bios() {
        let config = VmConfig {
            architecture: Architecture::Riscv64,
            firmware_path: "edk2-riscv-code.fd".to_owned(),
            disk_path: "linux-riscv64.qcow2".to_owned(),
            profile: GuestProfile::Linux,
            ..VmConfig::default()
        };
        let args = build_args(&config).unwrap();
        assert!(!args.iter().any(|arg| arg == "-bios"));
        assert!(
            args.windows(2).any(|pair| {
                pair[0] == "-machine" && pair[1].contains("virt,accel=tcg,pflash0=pflash0")
            })
        );
        assert!(args.windows(2).any(|pair| {
            pair[0] == "-blockdev"
                && pair[1]
                    == "node-name=pflash0,driver=file,read-only=on,filename=edk2-riscv-code.fd"
        }));
    }

    #[test]
    fn riscv_vars_template_is_copied_per_vm() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = env::temp_dir().join(format!(
            "accessible-utm-riscv-vars-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&root).unwrap();
        let code = root.join("edk2-riscv-code.fd");
        let template = root.join("edk2-riscv-vars.fd");
        let disk = root.join("guest.qcow2");
        fs::write(&code, b"code").unwrap();
        fs::write(&template, b"vars-template").unwrap();
        fs::write(&disk, b"disk").unwrap();

        let config = VmConfig {
            architecture: Architecture::Riscv64,
            firmware_path: code.to_string_lossy().into_owned(),
            disk_path: disk.to_string_lossy().into_owned(),
            profile: GuestProfile::Linux,
            ..VmConfig::default()
        };
        let args = build_args(&config).unwrap();
        let private_vars = root.join("guest-edk2-riscv-vars.fd");
        assert!(private_vars.is_file());
        assert_eq!(fs::read(&private_vars).unwrap(), b"vars-template");
        let private_text = private_vars.to_string_lossy();
        assert!(args.iter().any(|arg| {
            arg.starts_with("node-name=pflash1,driver=file,filename=")
                && arg.contains(private_text.as_ref())
        }));
        assert!(!args.iter().any(|arg| {
            arg == &format!(
                "node-name=pflash1,driver=file,filename={}",
                template.to_string_lossy()
            )
        }));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn preserves_accessible_android_x86_disk_contract() {
        let config = VmConfig {
            disk_path: "AccessibleAndroid.qcow2".to_owned(),
            ..VmConfig::default()
        };
        let args = build_args(&config).unwrap();
        assert!(
            args.iter().any(|arg| {
                arg == "virtio-blk-pci,drive=osdisk,bus=pcie.0,addr=0x6,bootindex=1"
            })
        );
        assert!(
            args.iter()
                .any(|arg| arg == "virtio-rng-pci,bus=pcie.0,addr=0x7")
        );
        assert!(
            args.iter()
                .any(|arg| arg == "virtio-net-pci,netdev=net0,bus=pcie.0,addr=0x8")
        );
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
        assert!(
            args.iter()
                .any(|arg| arg == "usb-kbd,bus=xhci.0,id=android-keyboard")
        );
        assert!(
            args.iter()
                .any(|arg| arg == "usb-tablet,bus=xhci.0,id=android-tablet")
        );
        assert!(
            args.iter()
                .any(|arg| arg == &format!("{},id=android-audio", host_audio_driver()))
        );
        assert!(args.iter().any(|arg| {
            arg == "virtio-sound-pci,audiodev=android-audio,streams=2,id=android-sound"
        }));
        assert!(!args.iter().any(|arg| arg == "-audio"));
    }

    #[test]
    fn supports_arm64_and_riscv64_qemu_programs() {
        assert_eq!(
            qemu_program_name(Architecture::Aarch64),
            "qemu-system-aarch64"
        );
        assert_eq!(
            qemu_program_name(Architecture::Riscv64),
            "qemu-system-riscv64"
        );
        assert_eq!(machine(Architecture::Aarch64), "virt");
        assert_eq!(machine(Architecture::Riscv64), "virt");
    }
}
