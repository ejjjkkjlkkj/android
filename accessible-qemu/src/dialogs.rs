use rfd::FileDialog;

pub fn pick_qemu_executable() -> Option<String> {
    let dialog = FileDialog::new().set_title("Choose QEMU executable");
    #[cfg(target_os = "windows")]
    let dialog = dialog.add_filter("Windows executable", &["exe"]);
    dialog.pick_file().map(path_to_string)
}

pub fn pick_android_iso() -> Option<String> {
    FileDialog::new()
        .set_title("Choose AccessibleAndroid ISO")
        .add_filter("ISO image", &["iso"])
        .pick_file()
        .map(path_to_string)
}

pub fn pick_virtual_disk() -> Option<String> {
    FileDialog::new()
        .set_title("Choose virtual disk")
        .add_filter("Virtual disks", &["qcow2", "qcow", "raw", "img", "vdi", "vmdk"])
        .pick_file()
        .map(path_to_string)
}

pub fn pick_configuration() -> Option<String> {
    FileDialog::new()
        .set_title("Open AccessibleQEMU configuration")
        .add_filter("AccessibleQEMU configuration", &["json"])
        .pick_file()
        .map(path_to_string)
}

pub fn save_configuration(default_name: &str) -> Option<String> {
    FileDialog::new()
        .set_title("Save AccessibleQEMU configuration")
        .add_filter("AccessibleQEMU configuration", &["json"])
        .set_file_name(default_name)
        .save_file()
        .map(path_to_string)
}

pub fn choose_serial_log(default_name: &str) -> Option<String> {
    FileDialog::new()
        .set_title("Choose serial log file")
        .add_filter("Text log", &["log", "txt"])
        .set_file_name(default_name)
        .save_file()
        .map(path_to_string)
}

fn path_to_string(path: std::path::PathBuf) -> String {
    path.to_string_lossy().into_owned()
}
