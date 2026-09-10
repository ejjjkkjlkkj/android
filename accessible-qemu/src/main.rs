use eframe::egui;
use serde_json::{json, Value};
use std::env;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

const OS_DISK_ID: &str = "osdisk";
const OS_DISK_PCI_ADDR: &str = "0x6";
const RNG_PCI_ADDR: &str = "0x7";
const NET_PCI_ADDR: &str = "0x8";

const HELP: &str = "AccessibleQEMU\n\nOptions:\n  --iso <path>             AccessibleAndroid ISO\n  --disk <path>            RAW/QCOW2/VDI/VMDK virtual disk\n  --firmware <path>        Optional OVMF/UEFI firmware image\n  --qemu <path>            qemu-system-x86_64 executable\n  --memory <MiB>           Guest memory, 1024..32768\n  --cpus <count>           Guest virtual CPUs, 1..16\n  --qmp-port <port>        Local QMP control port, default 4444\n  --autostart              Start VM immediately after opening GUI\n  --print-qemu-command     Print deterministic QEMU command and exit\n  --help, -h               Show this help and exit\n  --version                Show version and exit\n\nHardware contract:\n  OS disk: virtio-blk-pci at PCI 0000:00:06.0\n  RNG:     virtio-rng-pci at PCI 0000:00:07.0\n  Network: virtio-net-pci at PCI 0000:00:08.0\n";

enum Startup {
    Gui(AccessibleQemuApp),
    PrintCommand(AccessibleQemuApp),
    Exit,
}

struct AccessibleQemuApp {
    qemu_binary: String,
    iso_path: String,
    disk_path: String,
    firmware_path: String,
    memory_mib: u32,
    cpu_count: u32,
    qmp_port: u16,
    status: String,
    child: Option<Child>,
    autostart_pending: bool,
}

impl Default for AccessibleQemuApp {
    fn default() -> Self {
        Self {
            qemu_binary: default_qemu_binary(),
            iso_path: String::new(),
            disk_path: String::new(),
            firmware_path: String::new(),
            memory_mib: 4096,
            cpu_count: 4,
            qmp_port: 4444,
            status: "Stopped. Configure the virtual machine, then choose Start virtual machine."
                .to_owned(),
            child: None,
            autostart_pending: false,
        }
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

fn next_value(args: &mut impl Iterator<Item = String>, option: &str) -> Option<String> {
    match args.next() {
        Some(value) => Some(value),
        None => {
            eprintln!("ERROR: {option} requires a value");
            None
        }
    }
}

fn app_from_args() -> Startup {
    let mut app = AccessibleQemuApp::default();
    let mut args = env::args().skip(1);
    let mut print_command = false;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--iso" => {
                let Some(value) = next_value(&mut args, "--iso") else {
                    return Startup::Exit;
                };
                app.iso_path = value;
            }
            "--disk" => {
                let Some(value) = next_value(&mut args, "--disk") else {
                    return Startup::Exit;
                };
                app.disk_path = value;
            }
            "--firmware" => {
                let Some(value) = next_value(&mut args, "--firmware") else {
                    return Startup::Exit;
                };
                app.firmware_path = value;
            }
            "--qemu" => {
                let Some(value) = next_value(&mut args, "--qemu") else {
                    return Startup::Exit;
                };
                app.qemu_binary = value;
            }
            "--memory" => {
                let Some(value) = next_value(&mut args, "--memory") else {
                    return Startup::Exit;
                };
                match value.parse::<u32>() {
                    Ok(parsed) => app.memory_mib = parsed.clamp(1024, 32768),
                    Err(_) => {
                        eprintln!("ERROR: invalid --memory value: {value}");
                        return Startup::Exit;
                    }
                }
            }
            "--cpus" => {
                let Some(value) = next_value(&mut args, "--cpus") else {
                    return Startup::Exit;
                };
                match value.parse::<u32>() {
                    Ok(parsed) => app.cpu_count = parsed.clamp(1, 16),
                    Err(_) => {
                        eprintln!("ERROR: invalid --cpus value: {value}");
                        return Startup::Exit;
                    }
                }
            }
            "--qmp-port" => {
                let Some(value) = next_value(&mut args, "--qmp-port") else {
                    return Startup::Exit;
                };
                match value.parse::<u16>() {
                    Ok(parsed) if parsed > 0 => app.qmp_port = parsed,
                    _ => {
                        eprintln!("ERROR: invalid --qmp-port value: {value}");
                        return Startup::Exit;
                    }
                }
            }
            "--autostart" => app.autostart_pending = true,
            "--print-qemu-command" => print_command = true,
            "--help" | "-h" => {
                print!("{HELP}");
                return Startup::Exit;
            }
            "--version" => {
                println!("AccessibleQEMU {}", env!("CARGO_PKG_VERSION"));
                return Startup::Exit;
            }
            _ => {
                eprintln!("ERROR: unknown option: {arg}");
                return Startup::Exit;
            }
        }
    }

    if print_command {
        Startup::PrintCommand(app)
    } else {
        Startup::Gui(app)
    }
}

fn disk_format(path: &str) -> Result<&'static str, String> {
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
            "Unsupported virtual disk format for '{path}'. Use .raw, .img, .qcow2, .vdi or .vmdk."
        )),
    }
}

fn quote_for_display(value: &str) -> String {
    if value.is_empty() || value.chars().any(char::is_whitespace) {
        format!("\"{}\"", value.replace('"', "\\\""))
    } else {
        value.to_owned()
    }
}

fn read_qmp_response(reader: &mut BufReader<TcpStream>) -> Result<Value, String> {
    loop {
        let mut line = String::new();
        let bytes = reader
            .read_line(&mut line)
            .map_err(|error| format!("QMP read failed: {error}"))?;
        if bytes == 0 {
            return Err("QMP connection closed before a response was received.".to_owned());
        }

        let value: Value = serde_json::from_str(line.trim())
            .map_err(|error| format!("Invalid QMP JSON response: {error}"))?;
        if value.get("return").is_some() || value.get("error").is_some() {
            return Ok(value);
        }
    }
}

impl AccessibleQemuApp {
    fn qemu_accelerator() -> &'static str {
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

    fn validate_paths(&self) -> Result<(), String> {
        if self.iso_path.trim().is_empty() && self.disk_path.trim().is_empty() {
            return Err("Provide an ISO path, a virtual disk path, or both.".to_owned());
        }
        if !self.iso_path.trim().is_empty() && !Path::new(self.iso_path.trim()).is_file() {
            return Err(format!("ISO not found: {}", self.iso_path.trim()));
        }
        if !self.disk_path.trim().is_empty() && !Path::new(self.disk_path.trim()).is_file() {
            return Err(format!("Virtual disk not found: {}", self.disk_path.trim()));
        }
        if !self.firmware_path.trim().is_empty()
            && !Path::new(self.firmware_path.trim()).is_file()
        {
            return Err(format!("Firmware not found: {}", self.firmware_path.trim()));
        }
        Ok(())
    }

    fn qemu_args(&self) -> Result<Vec<String>, String> {
        let mut args = vec![
            "-name".to_owned(),
            "Accessible Android".to_owned(),
            "-machine".to_owned(),
            format!("q35,accel={}", Self::qemu_accelerator()),
            "-m".to_owned(),
            self.memory_mib.to_string(),
            "-smp".to_owned(),
            self.cpu_count.to_string(),
            "-qmp".to_owned(),
            format!("tcp:127.0.0.1:{},server=on,wait=off", self.qmp_port),
            "-monitor".to_owned(),
            "none".to_owned(),
        ];

        if !self.firmware_path.trim().is_empty() {
            args.push("-bios".to_owned());
            args.push(self.firmware_path.trim().to_owned());
        }

        if !self.disk_path.trim().is_empty() {
            let format = disk_format(self.disk_path.trim())?;
            args.push("-drive".to_owned());
            args.push(format!(
                "if=none,id={OS_DISK_ID},file={},format={format},cache=writeback",
                self.disk_path.trim()
            ));
            args.push("-device".to_owned());
            args.push(format!(
                "virtio-blk-pci,drive={OS_DISK_ID},bus=pcie.0,addr={OS_DISK_PCI_ADDR},bootindex=1"
            ));
        }

        args.extend([
            "-device".to_owned(),
            format!("virtio-rng-pci,bus=pcie.0,addr={RNG_PCI_ADDR}"),
            "-netdev".to_owned(),
            "user,id=net0".to_owned(),
            "-device".to_owned(),
            format!("virtio-net-pci,netdev=net0,bus=pcie.0,addr={NET_PCI_ADDR}"),
        ]);

        if !self.iso_path.trim().is_empty() {
            args.push("-cdrom".to_owned());
            args.push(self.iso_path.trim().to_owned());
            args.push("-boot".to_owned());
            args.push("menu=on,order=d".to_owned());
        } else if !self.disk_path.trim().is_empty() {
            args.push("-boot".to_owned());
            args.push("menu=on,order=c".to_owned());
        }

        Ok(args)
    }

    fn printable_qemu_command(&self) -> Result<String, String> {
        let args = self.qemu_args()?;
        let mut parts = Vec::with_capacity(args.len() + 1);
        parts.push(quote_for_display(self.qemu_binary.trim()));
        parts.extend(args.iter().map(|arg| quote_for_display(arg)));
        Ok(parts.join(" "))
    }

    fn refresh_process_state(&mut self) {
        let Some(child) = self.child.as_mut() else {
            return;
        };

        match child.try_wait() {
            Ok(Some(exit)) => {
                self.status = format!("Virtual machine stopped. QEMU exit status: {exit}.");
                self.child = None;
            }
            Ok(None) => {}
            Err(error) => {
                self.status = format!("Unable to query QEMU process state: {error}");
            }
        }
    }

    fn start_vm(&mut self) {
        self.refresh_process_state();
        if self.child.is_some() {
            self.status = "Virtual machine is already running.".to_owned();
            return;
        }

        if let Err(error) = self.validate_paths() {
            self.status = format!("Cannot start: {error}");
            return;
        }

        let args = match self.qemu_args() {
            Ok(args) => args,
            Err(error) => {
                self.status = format!("Cannot start: {error}");
                return;
            }
        };

        let mut command = Command::new(self.qemu_binary.trim());
        command
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());

        match command.spawn() {
            Ok(child) => {
                self.child = Some(child);
                self.status = format!(
                    "Virtual machine started. OS disk PCI address is 0000:00:06.0. QMP control is available locally on port {}.",
                    self.qmp_port
                );
            }
            Err(error) => {
                self.status = format!(
                    "Unable to start QEMU using '{}': {error}",
                    self.qemu_binary.trim()
                );
            }
        }
    }

    fn force_stop_vm(&mut self) {
        let Some(mut child) = self.child.take() else {
            self.status = "Virtual machine is already stopped.".to_owned();
            return;
        };

        match child.kill() {
            Ok(()) => {
                let _ = child.wait();
                self.status = "Virtual machine force-stopped.".to_owned();
            }
            Err(error) => {
                self.status = format!("Unable to force-stop QEMU: {error}");
                self.child = Some(child);
            }
        }
    }

    fn qmp_execute(&self, command: &str) -> Result<Value, String> {
        if self.child.is_none() {
            return Err("Virtual machine is not running.".to_owned());
        }

        let address = format!("127.0.0.1:{}", self.qmp_port);
        let stream = TcpStream::connect(&address)
            .map_err(|error| format!("Cannot connect to QMP at {address}: {error}"))?;
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .map_err(|error| format!("Cannot set QMP read timeout: {error}"))?;
        stream
            .set_write_timeout(Some(Duration::from_secs(2)))
            .map_err(|error| format!("Cannot set QMP write timeout: {error}"))?;

        let mut writer = stream
            .try_clone()
            .map_err(|error| format!("Cannot clone QMP socket: {error}"))?;
        let mut reader = BufReader::new(stream);

        let mut greeting = String::new();
        reader
            .read_line(&mut greeting)
            .map_err(|error| format!("Cannot read QMP greeting: {error}"))?;
        let greeting_json: Value = serde_json::from_str(greeting.trim())
            .map_err(|error| format!("Invalid QMP greeting: {error}"))?;
        if greeting_json.get("QMP").is_none() {
            return Err("QMP server did not send a valid greeting.".to_owned());
        }

        writeln!(writer, "{}", json!({"execute": "qmp_capabilities"}))
            .map_err(|error| format!("Cannot negotiate QMP capabilities: {error}"))?;
        writer
            .flush()
            .map_err(|error| format!("Cannot flush QMP capabilities request: {error}"))?;
        let capability_response = read_qmp_response(&mut reader)?;
        if let Some(error) = capability_response.get("error") {
            return Err(format!("QMP capability negotiation failed: {error}"));
        }

        writeln!(writer, "{}", json!({"execute": command}))
            .map_err(|error| format!("Cannot send QMP command {command}: {error}"))?;
        writer
            .flush()
            .map_err(|error| format!("Cannot flush QMP command {command}: {error}"))?;
        let response = read_qmp_response(&mut reader)?;
        if let Some(error) = response.get("error") {
            return Err(format!("QMP command {command} failed: {error}"));
        }
        Ok(response)
    }

    fn run_qmp_action(&mut self, command: &str, success_message: &str) {
        match self.qmp_execute(command) {
            Ok(_) => self.status = success_message.to_owned(),
            Err(error) => self.status = error,
        }
    }

    fn query_qmp_status(&mut self) {
        match self.qmp_execute("query-status") {
            Ok(response) => {
                let state = response
                    .get("return")
                    .and_then(|value| value.get("status"))
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                self.status = format!("Virtual machine QMP status: {state}.");
            }
            Err(error) => self.status = error,
        }
    }

    fn render(&mut self, ui: &mut egui::Ui) {
        ui.heading("AccessibleQEMU");
        ui.label("Accessibility-first graphical virtual machine manager");
        ui.label("Deterministic Android OS disk: virtio-blk PCI 0000:00:06.0");
        ui.separator();

        ui.heading("Virtual machine configuration");
        ui.add_space(8.0);

        egui::Grid::new("vm_configuration_grid")
            .num_columns(2)
            .spacing([16.0, 10.0])
            .show(ui, |ui| {
                let label = ui.label("QEMU executable");
                ui.text_edit_singleline(&mut self.qemu_binary)
                    .on_hover_text("Path or command name for qemu-system-x86_64")
                    .labelled_by(label.id);
                ui.end_row();

                let label = ui.label("Android ISO path");
                ui.text_edit_singleline(&mut self.iso_path)
                    .on_hover_text("Optional AccessibleAndroid bootable ISO")
                    .labelled_by(label.id);
                ui.end_row();

                let label = ui.label("Virtual disk path");
                ui.text_edit_singleline(&mut self.disk_path)
                    .on_hover_text("RAW, IMG, QCOW2, VDI or VMDK AccessibleAndroid disk")
                    .labelled_by(label.id);
                ui.end_row();

                let label = ui.label("UEFI firmware path");
                ui.text_edit_singleline(&mut self.firmware_path)
                    .on_hover_text("Optional OVMF firmware; leave empty for legacy BIOS")
                    .labelled_by(label.id);
                ui.end_row();

                let label = ui.label("Memory");
                ui.add(
                    egui::Slider::new(&mut self.memory_mib, 1024..=32768)
                        .text("Memory in MiB")
                        .step_by(512.0),
                )
                .labelled_by(label.id);
                ui.end_row();

                let label = ui.label("Processors");
                ui.add(
                    egui::Slider::new(&mut self.cpu_count, 1..=16)
                        .text("Virtual processor count"),
                )
                .labelled_by(label.id);
                ui.end_row();

                let label = ui.label("QMP local port");
                ui.add(
                    egui::DragValue::new(&mut self.qmp_port)
                        .range(1024..=65535)
                        .speed(1.0),
                )
                .labelled_by(label.id);
                ui.end_row();
            });

        ui.add_space(16.0);
        ui.heading("Virtual machine controls");
        ui.horizontal_wrapped(|ui| {
            let running = self.child.is_some();

            if ui
                .add_enabled(!running, egui::Button::new("Start virtual machine"))
                .clicked()
            {
                self.start_vm();
            }
            if ui
                .add_enabled(running, egui::Button::new("Pause virtual machine"))
                .clicked()
            {
                self.run_qmp_action("stop", "Virtual machine paused through QMP.");
            }
            if ui
                .add_enabled(running, egui::Button::new("Resume virtual machine"))
                .clicked()
            {
                self.run_qmp_action("cont", "Virtual machine resumed through QMP.");
            }
            if ui
                .add_enabled(running, egui::Button::new("Reset virtual machine"))
                .clicked()
            {
                self.run_qmp_action("system_reset", "Virtual machine reset requested through QMP.");
            }
            if ui
                .add_enabled(running, egui::Button::new("Request graceful shutdown"))
                .clicked()
            {
                self.run_qmp_action(
                    "system_powerdown",
                    "Graceful guest shutdown requested through QMP.",
                );
            }
            if ui
                .add_enabled(running, egui::Button::new("Force stop virtual machine"))
                .clicked()
            {
                self.force_stop_vm();
            }
            if ui
                .add_enabled(running, egui::Button::new("Query virtual machine status"))
                .clicked()
            {
                self.query_qmp_status();
            }
        });

        ui.add_space(16.0);
        ui.heading("Status");
        ui.label(&self.status);

        ui.add_space(16.0);
        ui.heading("Keyboard navigation");
        ui.label(
            "Use Tab and Shift+Tab to move between controls, arrow keys to adjust values, and Enter or Space to activate the focused control. Every VM lifecycle command above is available without a mouse.",
        );
    }
}

impl Drop for AccessibleQemuApp {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

impl eframe::App for AccessibleQemuApp {
    fn logic(&mut self, _ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.refresh_process_state();
        if self.autostart_pending {
            self.autostart_pending = false;
            self.start_vm();
        }
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        egui::CentralPanel::default().show(ui, |ui| self.render(ui));
    }
}

fn main() -> eframe::Result<()> {
    match app_from_args() {
        Startup::Exit => Ok(()),
        Startup::PrintCommand(app) => match app.printable_qemu_command() {
            Ok(command) => {
                println!("{command}");
                Ok(())
            }
            Err(error) => {
                eprintln!("ERROR: {error}");
                std::process::exit(2);
            }
        },
        Startup::Gui(app) => {
            let options = eframe::NativeOptions::default();
            eframe::run_native(
                "AccessibleQEMU",
                options,
                Box::new(move |_creation_context| Ok(Box::new(app))),
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_supported_disk_formats() {
        assert_eq!(disk_format("disk.qcow2").unwrap(), "qcow2");
        assert_eq!(disk_format("disk.raw").unwrap(), "raw");
        assert_eq!(disk_format("disk.img").unwrap(), "raw");
        assert_eq!(disk_format("disk.vdi").unwrap(), "vdi");
        assert_eq!(disk_format("disk.vmdk").unwrap(), "vmdk");
        assert!(disk_format("disk.iso").is_err());
    }

    #[test]
    fn pins_android_disk_and_devices_to_stable_pci_addresses() {
        let app = AccessibleQemuApp {
            disk_path: "AccessibleAndroid.qcow2".to_owned(),
            ..AccessibleQemuApp::default()
        };
        let args = app.qemu_args().unwrap();
        assert!(args.iter().any(|arg| {
            arg == "virtio-blk-pci,drive=osdisk,bus=pcie.0,addr=0x6,bootindex=1"
        }));
        assert!(args
            .iter()
            .any(|arg| arg == "virtio-rng-pci,bus=pcie.0,addr=0x7"));
        assert!(args
            .iter()
            .any(|arg| arg == "virtio-net-pci,netdev=net0,bus=pcie.0,addr=0x8"));
        assert!(args
            .iter()
            .any(|arg| arg.contains("if=none,id=osdisk") && arg.contains("format=qcow2")));
    }
}
