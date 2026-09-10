use crate::config::VmConfig;
use std::path::Path;
use std::process::{Command, Stdio};

pub const OS_DISK_PCI_ADDRESS: &str = "0x6";
pub const NETWORK_PCI_ADDRESS: &str = "0x7";
pub const RNG_PCI_ADDRESS: &str = "0x8";
pub const CDROM_BACKEND_ID: &str = "accessible-cdrom-backend";
pub const CDROM_DEVICE_ID: &str = "accessible-cdrom";

#[derive(Clone, Debug)]
pub struct QemuLaunchPlan {
    pub program: String,
    pub args: Vec<String>,
}

impl QemuLaunchPlan {
    pub fn command(&self) -> Command {
        let mut command = Command::new(&self.program);
        command
            .args(&self.args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        command
    }

    pub fn display(&self) -> String {
        let mut parts = Vec::with_capacity(self.args.len() + 1);
        parts.push(quote_for_display(&self.program));
        parts.extend(self.args.iter().map(|arg| quote_for_display(arg)));
        parts.join(" ")
    }
}

pub fn build_launch_plan(config: &VmConfig) -> Result<QemuLaunchPlan, String> {
    config.validate()?;

    let mut args = vec![
        "-name".to_owned(),
        config.name.clone(),
        "-machine".to_owned(),
        format!("q35,accel={}", accelerator()),
        "-m".to_owned(),
        config.memory_mib.to_string(),
        "-smp".to_owned(),
        config.cpu_count.to_string(),
        "-qmp".to_owned(),
        format!("tcp:127.0.0.1:{},server=on,wait=off", config.qmp_port),
        "-monitor".to_owned(),
        "none".to_owned(),
    ];

    if !config.serial_log_path.trim().is_empty() {
        args.push("-chardev".to_owned());
        args.push(format!(
            "file,id=accessible_serial,path={},append=on",
            qemu_keyval_escape(config.serial_log_path.trim())
        ));
        args.push("-serial".to_owned());
        args.push("chardev:accessible_serial".to_owned());
    }

    if !config.disk_path.trim().is_empty() {
        let disk_format = detect_disk_format(config.disk_path.trim())?;
        args.push("-drive".to_owned());
        args.push(format!(
            "file={},if=none,id=osdisk,format={disk_format},cache=writeback,aio=threads",
            qemu_keyval_escape(config.disk_path.trim())
        ));
        args.push("-device".to_owned());
        args.push(format!(
            "virtio-blk-pci,drive=osdisk,bus=pcie.0,addr={OS_DISK_PCI_ADDRESS}"
        ));
    }

    args.push("-netdev".to_owned());
    args.push("user,id=net0".to_owned());
    args.push("-device".to_owned());
    args.push(format!(
        "virtio-net-pci,netdev=net0,bus=pcie.0,addr={NETWORK_PCI_ADDRESS}"
    ));
    args.push("-device".to_owned());
    args.push(format!(
        "virtio-rng-pci,bus=pcie.0,addr={RNG_PCI_ADDRESS}"
    ));

    // Keep an explicit removable CD-ROM device even when no ISO is inserted.
    // This gives QMP a stable qdev id for accessible insert/eject operations.
    args.push("-drive".to_owned());
    let mut cdrom_drive = format!(
        "if=none,media=cdrom,id={CDROM_BACKEND_ID},readonly=on,format=raw"
    );
    if !config.iso_path.trim().is_empty() {
        cdrom_drive.push_str(&format!(
            ",file={}",
            qemu_keyval_escape(config.iso_path.trim())
        ));
    }
    args.push(cdrom_drive);
    args.push("-device".to_owned());
    args.push(format!(
        "ide-cd,bus=ide.0,drive={CDROM_BACKEND_ID},id={CDROM_DEVICE_ID},bootindex=0"
    ));

    args.push("-boot".to_owned());
    if config.iso_path.trim().is_empty() {
        args.push("menu=on,order=c".to_owned());
    } else {
        args.push("menu=on,order=d".to_owned());
    }

    Ok(QemuLaunchPlan {
        program: config.qemu_binary.trim().to_owned(),
        args,
    })
}

pub fn detect_disk_format(path: &str) -> Result<&'static str, String> {
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
        _ => Err(format!(
            "Unsupported virtual disk extension for '{path}'. Supported formats: RAW/IMG, QCOW2, VDI, VMDK."
        )),
    }
}

pub fn accelerator() -> &'static str {
    #[cfg(target_os = "linux")]
    {
        "kvm:tcg"
    }
    #[cfg(target_os = "windows")]
    {
        "whpx:tcg"
    }
    #[cfg(target_os = "macos")]
    {
        "hvf:tcg"
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows", target_os = "macos")))]
    {
        "tcg"
    }
}

fn qemu_keyval_escape(value: &str) -> String {
    value.replace(',', ",,")
}

fn quote_for_display(value: &str) -> String {
    if value.is_empty() {
        return "\"\"".to_owned();
    }
    if value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || "-_=./:\\,".contains(ch))
    {
        return value.to_owned();
    }
    format!("\"{}\"", value.replace('"', "\\\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_supported_disk_formats() {
        assert_eq!(detect_disk_format("disk.qcow2").unwrap(), "qcow2");
        assert_eq!(detect_disk_format("disk.RAW").unwrap(), "raw");
        assert_eq!(detect_disk_format("disk.img").unwrap(), "raw");
        assert_eq!(detect_disk_format("disk.vdi").unwrap(), "vdi");
        assert_eq!(detect_disk_format("disk.vmdk").unwrap(), "vmdk");
        assert!(detect_disk_format("disk.iso").is_err());
    }
}
