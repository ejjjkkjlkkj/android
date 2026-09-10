mod config;
mod dialogs;
mod qemu;
mod qmp;

use config::VmConfig;
use eframe::egui;
use qmp::QmpClient;
use std::env;
use std::path::Path;
use std::process::Child;

const HELP: &str = "AccessibleQEMU\n\nOptions:\n  --config <path>        Load a JSON VM configuration\n  --iso <path>           AccessibleAndroid ISO\n  --disk <path>          RAW/QCOW2/VDI/VMDK virtual disk\n  --qemu <path>          qemu-system-x86_64 executable\n  --memory <MiB>         Guest memory, 1024..32768\n  --cpus <count>         Guest virtual CPUs, 1..16\n  --qmp-port <port>      Local QMP control port, 1024..65535\n  --serial-log <path>    Guest serial console log\n  --write-config <path>  Save resolved configuration and exit\n  --print-qemu-command   Print deterministic QEMU command and exit\n  --autostart            Start VM immediately after opening GUI\n  --help, -h             Show this help and exit\n  --version              Show version and exit\n";

enum Startup {
    Gui(AccessibleQemuApp),
    Exit,
}

struct AccessibleQemuApp {
    config: VmConfig,
    config_path: String,
    status: String,
    child: Option<Child>,
    autostart_pending: bool,
}

impl Default for AccessibleQemuApp {
    fn default() -> Self {
        Self {
            config: VmConfig::default(),
            config_path: "accessible-android-17.aqemu.json".to_owned(),
            status: "Stopped. Configure the virtual machine, then choose Start virtual machine."
                .to_owned(),
            child: None,
            autostart_pending: false,
        }
    }
}

fn argument_value(args: &[String], key: &str) -> Option<String> {
    args.windows(2)
        .find(|pair| pair[0] == key)
        .map(|pair| pair[1].clone())
}

fn parse_u32_arg(args: &[String], key: &str, minimum: u32, maximum: u32) -> Option<u32> {
    argument_value(args, key)
        .and_then(|value| value.parse::<u32>().ok())
        .map(|value| value.clamp(minimum, maximum))
}

fn parse_u16_arg(args: &[String], key: &str, minimum: u16) -> Option<u16> {
    argument_value(args, key)
        .and_then(|value| value.parse::<u16>().ok())
        .filter(|value| *value >= minimum)
}

fn app_from_args() -> Startup {
    let args: Vec<String> = env::args().skip(1).collect();

    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        print!("{HELP}");
        return Startup::Exit;
    }
    if args.iter().any(|arg| arg == "--version") {
        println!("AccessibleQEMU {}", env!("CARGO_PKG_VERSION"));
        return Startup::Exit;
    }

    let mut app = AccessibleQemuApp::default();

    if let Some(path) = argument_value(&args, "--config") {
        match VmConfig::load(Path::new(&path)) {
            Ok(config) => {
                app.config = config;
                app.config_path = path;
            }
            Err(error) => {
                eprintln!("ERROR: {error}");
                return Startup::Exit;
            }
        }
    }

    if let Some(value) = argument_value(&args, "--iso") {
        app.config.iso_path = value;
    }
    if let Some(value) = argument_value(&args, "--disk") {
        app.config.disk_path = value;
    }
    if let Some(value) = argument_value(&args, "--qemu") {
        app.config.qemu_binary = value;
    }
    if let Some(value) = parse_u32_arg(&args, "--memory", 1024, 32768) {
        app.config.memory_mib = value;
    }
    if let Some(value) = parse_u32_arg(&args, "--cpus", 1, 16) {
        app.config.cpu_count = value;
    }
    if let Some(value) = parse_u16_arg(&args, "--qmp-port", 1024) {
        app.config.qmp_port = value;
    }
    if let Some(value) = argument_value(&args, "--serial-log") {
        app.config.serial_log_path = value;
    }
    app.autostart_pending = args.iter().any(|arg| arg == "--autostart");

    if let Some(path) = argument_value(&args, "--write-config") {
        match app.config.save(Path::new(&path)) {
            Ok(()) => println!("CONFIG_SAVED = {path}"),
            Err(error) => eprintln!("ERROR: {error}"),
        }
        return Startup::Exit;
    }

    if args.iter().any(|arg| arg == "--print-qemu-command") {
        match qemu::build_launch_plan(&app.config) {
            Ok(plan) => println!("{}", plan.display()),
            Err(error) => eprintln!("ERROR: {error}"),
        }
        return Startup::Exit;
    }

    Startup::Gui(app)
}

impl AccessibleQemuApp {
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

        let plan = match qemu::build_launch_plan(&self.config) {
            Ok(plan) => plan,
            Err(error) => {
                self.status = format!("Cannot start: {error}");
                return;
            }
        };

        match plan.command().spawn() {
            Ok(child) => {
                self.child = Some(child);
                self.status = format!(
                    "Virtual machine started. QMP is local on port {}. Android OS disk uses PCI 00:06.0. Serial log: {}.",
                    self.config.qmp_port,
                    self.config.serial_log_path
                );
            }
            Err(error) => {
                self.status = format!(
                    "Unable to start QEMU using '{}': {error}",
                    self.config.qemu_binary.trim()
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

    fn qmp_client(&self) -> Result<QmpClient, String> {
        if self.child.is_none() {
            return Err("Virtual machine is not running.".to_owned());
        }
        Ok(QmpClient::new(self.config.qmp_port))
    }

    fn run_qmp_action(&mut self, command: &str, success_message: &str) {
        let result = self
            .qmp_client()
            .and_then(|client| client.execute(command, None));
        self.status = match result {
            Ok(_) => success_message.to_owned(),
            Err(error) => error,
        };
    }

    fn query_qmp_status(&mut self) {
        let result = self.qmp_client().and_then(|client| client.query_status());
        self.status = match result {
            Ok(state) => format!("Virtual machine QMP status: {state}."),
            Err(error) => error,
        };
    }

    fn save_config(&mut self) {
        match self.config.save(Path::new(self.config_path.trim())) {
            Ok(()) => {
                self.status = format!("Configuration saved to {}.", self.config_path.trim());
            }
            Err(error) => self.status = error,
        }
    }

    fn load_config(&mut self) {
        match VmConfig::load(Path::new(self.config_path.trim())) {
            Ok(config) => {
                self.config = config;
                self.status = format!("Configuration loaded from {}.", self.config_path.trim());
            }
            Err(error) => self.status = error,
        }
    }

    fn choose_and_load_config(&mut self) {
        if let Some(path) = dialogs::pick_configuration() {
            self.config_path = path;
            self.load_config();
        }
    }

    fn choose_and_save_config(&mut self) {
        if let Some(path) = dialogs::save_configuration("accessible-android-17.aqemu.json") {
            self.config_path = path;
            self.save_config();
        }
    }

    fn validate_config(&mut self) {
        self.status = match self.config.validate() {
            Ok(()) => "Configuration validation passed.".to_owned(),
            Err(error) => format!("Configuration validation failed: {error}"),
        };
    }

    fn show_qemu_command(&mut self) {
        self.status = match qemu::build_launch_plan(&self.config) {
            Ok(plan) => format!("QEMU command: {}", plan.display()),
            Err(error) => format!("Cannot build QEMU command: {error}"),
        };
    }

    fn render(&mut self, ui: &mut egui::Ui) {
        ui.heading("AccessibleQEMU");
        ui.label("Accessibility-first graphical virtual machine manager for Windows and QEMU");
        ui.separator();

        ui.heading("Virtual machine configuration");
        ui.add_space(8.0);

        egui::Grid::new("vm_configuration_grid")
            .num_columns(3)
            .spacing([16.0, 10.0])
            .show(ui, |ui| {
                let label = ui.label("Virtual machine name");
                ui.text_edit_singleline(&mut self.config.name)
                    .on_hover_text("Accessible name stored in the VM configuration")
                    .labelled_by(label.id);
                ui.label("");
                ui.end_row();

                let label = ui.label("QEMU executable");
                ui.text_edit_singleline(&mut self.config.qemu_binary)
                    .on_hover_text("Path or command name for qemu-system-x86_64")
                    .labelled_by(label.id);
                if ui.button("Browse for QEMU executable").clicked() {
                    if let Some(path) = dialogs::pick_qemu_executable() {
                        self.config.qemu_binary = path;
                    }
                }
                ui.end_row();

                let label = ui.label("Android ISO path");
                ui.text_edit_singleline(&mut self.config.iso_path)
                    .on_hover_text("Optional path to the AccessibleAndroid bootable ISO")
                    .labelled_by(label.id);
                if ui.button("Browse for Android ISO").clicked() {
                    if let Some(path) = dialogs::pick_android_iso() {
                        self.config.iso_path = path;
                    }
                }
                ui.end_row();

                let label = ui.label("Virtual disk path");
                ui.text_edit_singleline(&mut self.config.disk_path)
                    .on_hover_text("RAW/IMG, QCOW2, VDI or VMDK disk. AccessibleAndroid uses PCI 00:06.0")
                    .labelled_by(label.id);
                if ui.button("Browse for virtual disk").clicked() {
                    if let Some(path) = dialogs::pick_virtual_disk() {
                        self.config.disk_path = path;
                    }
                }
                ui.end_row();

                let label = ui.label("Serial log path");
                ui.text_edit_singleline(&mut self.config.serial_log_path)
                    .on_hover_text("Text log for the guest serial console; usable when the graphical display fails")
                    .labelled_by(label.id);
                if ui.button("Choose serial log file").clicked() {
                    if let Some(path) = dialogs::choose_serial_log("accessible-qemu-serial.log") {
                        self.config.serial_log_path = path;
                    }
                }
                ui.end_row();

                let label = ui.label("Memory");
                ui.add(
                    egui::Slider::new(&mut self.config.memory_mib, 1024..=32768)
                        .text("Memory in MiB")
                        .step_by(512.0),
                )
                .labelled_by(label.id);
                ui.label("");
                ui.end_row();

                let label = ui.label("Processors");
                ui.add(
                    egui::Slider::new(&mut self.config.cpu_count, 1..=16)
                        .text("Virtual processor count"),
                )
                .labelled_by(label.id);
                ui.label("");
                ui.end_row();

                let label = ui.label("QMP local port");
                ui.add(
                    egui::DragValue::new(&mut self.config.qmp_port)
                        .range(1024..=65535)
                        .speed(1.0),
                )
                .labelled_by(label.id);
                ui.label("");
                ui.end_row();

                let label = ui.label("Configuration file path");
                ui.text_edit_singleline(&mut self.config_path)
                    .on_hover_text("JSON file used to save or load this VM configuration")
                    .labelled_by(label.id);
                if ui.button("Browse for configuration file").clicked() {
                    if let Some(path) = dialogs::pick_configuration() {
                        self.config_path = path;
                    }
                }
                ui.end_row();
            });

        ui.add_space(12.0);
        ui.heading("Configuration actions");
        ui.horizontal_wrapped(|ui| {
            let running = self.child.is_some();
            if ui
                .add_enabled(!running, egui::Button::new("Validate configuration"))
                .clicked()
            {
                self.validate_config();
            }
            if ui
                .add_enabled(!running, egui::Button::new("Show QEMU command"))
                .clicked()
            {
                self.show_qemu_command();
            }
            if ui
                .add_enabled(!running, egui::Button::new("Save configuration"))
                .clicked()
            {
                self.save_config();
            }
            if ui
                .add_enabled(!running, egui::Button::new("Save configuration as"))
                .clicked()
            {
                self.choose_and_save_config();
            }
            if ui
                .add_enabled(!running, egui::Button::new("Load configuration"))
                .clicked()
            {
                self.load_config();
            }
            if ui
                .add_enabled(!running, egui::Button::new("Open configuration file"))
                .clicked()
            {
                self.choose_and_load_config();
            }
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
        ui.heading("Status and diagnostics");
        ui.label(&self.status);
        ui.label(format!(
            "Accelerator: {}. OS disk PCI: 00:06.0. Network PCI: 00:07.0. RNG PCI: 00:08.0.",
            qemu::accelerator()
        ));

        ui.add_space(16.0);
        ui.heading("Keyboard navigation");
        ui.label(
            "Use Tab and Shift+Tab to move between controls, arrow keys to adjust values, and Enter or Space to activate the focused control. Native Browse/Open/Save dialogs are available so paths do not have to be typed manually.",
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
