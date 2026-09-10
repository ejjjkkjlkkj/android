use eframe::egui;
use serde_json::{json, Value};
use std::env;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

const HELP: &str = "AccessibleQEMU\n\nOptions:\n  --iso <path>       AccessibleAndroid ISO\n  --disk <path>      QCOW2 virtual disk\n  --qemu <path>      qemu-system-x86_64 executable\n  --memory <MiB>     Guest memory, 1024..32768\n  --cpus <count>     Guest virtual CPUs, 1..16\n  --qmp-port <port>  Local QMP control port, default 4444\n  --autostart        Start VM immediately after opening GUI\n  --help, -h         Show this help and exit\n  --version          Show version and exit\n";

enum Startup {
    Gui(AccessibleQemuApp),
    Exit,
}

struct AccessibleQemuApp {
    qemu_binary: String,
    iso_path: String,
    disk_path: String,
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

fn app_from_args() -> Startup {
    let mut app = AccessibleQemuApp::default();
    let mut args = env::args().skip(1);

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--iso" => {
                if let Some(value) = args.next() {
                    app.iso_path = value;
                }
            }
            "--disk" => {
                if let Some(value) = args.next() {
                    app.disk_path = value;
                }
            }
            "--qemu" => {
                if let Some(value) = args.next() {
                    app.qemu_binary = value;
                }
            }
            "--memory" => {
                if let Some(value) = args.next() {
                    if let Ok(parsed) = value.parse::<u32>() {
                        app.memory_mib = parsed.clamp(1024, 32768);
                    }
                }
            }
            "--cpus" => {
                if let Some(value) = args.next() {
                    if let Ok(parsed) = value.parse::<u32>() {
                        app.cpu_count = parsed.clamp(1, 16);
                    }
                }
            }
            "--qmp-port" => {
                if let Some(value) = args.next() {
                    if let Ok(parsed) = value.parse::<u16>() {
                        if parsed > 0 {
                            app.qmp_port = parsed;
                        }
                    }
                }
            }
            "--autostart" => app.autostart_pending = true,
            "--help" | "-h" => {
                print!("{HELP}");
                return Startup::Exit;
            }
            "--version" => {
                println!("AccessibleQEMU {}", env!("CARGO_PKG_VERSION"));
                return Startup::Exit;
            }
            _ => {}
        }
    }

    Startup::Gui(app)
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

        if self.iso_path.trim().is_empty() && self.disk_path.trim().is_empty() {
            self.status =
                "Cannot start: provide an ISO path, a virtual disk path, or both.".to_owned();
            return;
        }

        if !self.iso_path.trim().is_empty() && !Path::new(self.iso_path.trim()).is_file() {
            self.status = format!("Cannot start: ISO not found: {}", self.iso_path.trim());
            return;
        }

        if !self.disk_path.trim().is_empty() && !Path::new(self.disk_path.trim()).is_file() {
            self.status = format!("Cannot start: virtual disk not found: {}", self.disk_path.trim());
            return;
        }

        let mut command = Command::new(self.qemu_binary.trim());
        command
            .arg("-name")
            .arg("Accessible Android")
            .arg("-machine")
            .arg(format!("q35,accel={}", Self::qemu_accelerator()))
            .arg("-m")
            .arg(self.memory_mib.to_string())
            .arg("-smp")
            .arg(self.cpu_count.to_string())
            .arg("-qmp")
            .arg(format!(
                "tcp:127.0.0.1:{},server=on,wait=off",
                self.qmp_port
            ))
            .arg("-monitor")
            .arg("none")
            .arg("-device")
            .arg("virtio-rng-pci")
            .arg("-netdev")
            .arg("user,id=net0")
            .arg("-device")
            .arg("virtio-net-pci,netdev=net0")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());

        if !self.disk_path.trim().is_empty() {
            command
                .arg("-drive")
                .arg(format!("file={},if=virtio,format=qcow2", self.disk_path.trim()));
        }

        if !self.iso_path.trim().is_empty() {
            command
                .arg("-cdrom")
                .arg(self.iso_path.trim())
                .arg("-boot")
                .arg("menu=on,order=d");
        }

        match command.spawn() {
            Ok(child) => {
                self.child = Some(child);
                self.status = format!(
                    "Virtual machine started. QMP control is available locally on port {}.",
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
                    .on_hover_text("Path to the Accessible Android bootable ISO")
                    .labelled_by(label.id);
                ui.end_row();

                let label = ui.label("Virtual disk path");
                ui.text_edit_singleline(&mut self.disk_path)
                    .on_hover_text("Path to an existing QCOW2 virtual disk")
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
    let Startup::Gui(app) = app_from_args() else {
        return Ok(());
    };

    let options = eframe::NativeOptions::default();
    eframe::run_native(
        "AccessibleQEMU",
        options,
        Box::new(move |_creation_context| Ok(Box::new(app))),
    )
}
