mod config;
mod qemu;

use config::{Architecture, GuestProfile, VmConfig};
use eframe::egui;
use qemu::{build_args, default_qemu_binary, printable_command, validate_media};
use serde_json::{Value, json};
use std::env;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;

const HELP: &str = "AccessibleUTM Windows\n\nOptions:\n  --profile <name>       accessible-android|linux|windows|generic\n  --arch <name>          x86_64|aarch64|riscv64\n  --name <name>          Virtual machine name\n  --iso <path>           Bootable ISO image\n  --disk <path>          RAW/QCOW2/VDI/VMDK/VHD/VHDX virtual disk\n  --firmware <path>      Optional firmware/UEFI image\n  --qemu <path>          QEMU system executable\n  --memory <MiB>         Guest memory, 1024..65536\n  --cpus <count>         Guest virtual CPUs, 1..32\n  --qmp-port <port>      Local QMP control port, default 4444\n  --config <path>        VM configuration JSON path for load/save\n  --autostart            Start VM immediately after opening GUI\n  --print-qemu-command   Print generated QEMU command and exit\n  --help, -h             Show this help and exit\n  --version              Show version and exit\n\nKeyboard:\n  F5                     Start virtual machine\n  F6                     Pause virtual machine\n  F7                     Resume virtual machine\n  F8                     Request graceful shutdown\n  F9                     Print QEMU command\n  Ctrl+S                 Save configuration\n  Ctrl+O                 Load configuration\n\nAccessibleAndroid x86_64 contract:\n  OS disk: virtio-blk-pci at PCI 0000:00:06.0\n  RNG:     virtio-rng-pci at PCI 0000:00:07.0\n  Network: virtio-net-pci at PCI 0000:00:08.0\n";

enum Startup {
    Gui(AccessibleUtmApp),
    PrintCommand(AccessibleUtmApp),
    Exit,
}

struct AccessibleUtmApp {
    config: VmConfig,
    config_path: PathBuf,
    status: String,
    child: Option<Child>,
    autostart_pending: bool,
}

impl Default for AccessibleUtmApp {
    fn default() -> Self {
        let mut config = VmConfig::default();
        config.qemu_binary = default_qemu_binary(config.architecture);
        Self {
            config,
            config_path: PathBuf::from("AccessibleUTM.json"),
            status: "Stopped. Configure a virtual machine, then choose Start virtual machine."
                .to_owned(),
            child: None,
            autostart_pending: false,
        }
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

fn load_cli_config(app: &mut AccessibleUtmApp, path: &Path) -> Result<(), String> {
    app.config_path = path.to_path_buf();
    if path.exists() {
        app.config = VmConfig::load(path)?;
    }
    Ok(())
}

fn app_from_args() -> Startup {
    let mut app = AccessibleUtmApp::default();
    let mut args = env::args().skip(1);
    let mut print_command = false;
    let mut qemu_overridden = false;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--profile" => {
                let Some(value) = next_value(&mut args, "--profile") else {
                    return Startup::Exit;
                };
                let Some(profile) = GuestProfile::from_cli(&value) else {
                    eprintln!("ERROR: unsupported profile: {value}");
                    return Startup::Exit;
                };
                app.config.profile = profile;
                if profile != GuestProfile::AccessibleAndroid
                    && app.config.name == "AccessibleAndroid"
                {
                    app.config.name = profile.label().to_owned();
                }
            }
            "--arch" => {
                let Some(value) = next_value(&mut args, "--arch") else {
                    return Startup::Exit;
                };
                let Some(architecture) = Architecture::from_cli(&value) else {
                    eprintln!("ERROR: unsupported architecture: {value}");
                    return Startup::Exit;
                };
                app.config.architecture = architecture;
            }
            "--name" => {
                let Some(value) = next_value(&mut args, "--name") else {
                    return Startup::Exit;
                };
                app.config.name = value;
            }
            "--iso" => {
                let Some(value) = next_value(&mut args, "--iso") else {
                    return Startup::Exit;
                };
                app.config.iso_path = value;
            }
            "--disk" => {
                let Some(value) = next_value(&mut args, "--disk") else {
                    return Startup::Exit;
                };
                app.config.disk_path = value;
            }
            "--firmware" => {
                let Some(value) = next_value(&mut args, "--firmware") else {
                    return Startup::Exit;
                };
                app.config.firmware_path = value;
            }
            "--qemu" => {
                let Some(value) = next_value(&mut args, "--qemu") else {
                    return Startup::Exit;
                };
                app.config.qemu_binary = value;
                qemu_overridden = true;
            }
            "--memory" => {
                let Some(value) = next_value(&mut args, "--memory") else {
                    return Startup::Exit;
                };
                match value.parse::<u32>() {
                    Ok(parsed) => app.config.memory_mib = parsed.clamp(1024, 65536),
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
                    Ok(parsed) => app.config.cpu_count = parsed.clamp(1, 32),
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
                    Ok(parsed) if parsed > 0 => app.config.qmp_port = parsed,
                    _ => {
                        eprintln!("ERROR: invalid --qmp-port value: {value}");
                        return Startup::Exit;
                    }
                }
            }
            "--config" => {
                let Some(value) = next_value(&mut args, "--config") else {
                    return Startup::Exit;
                };
                let path = PathBuf::from(value);
                if let Err(error) = load_cli_config(&mut app, &path) {
                    eprintln!("ERROR: {error}");
                    return Startup::Exit;
                }
                qemu_overridden = !app.config.qemu_binary.trim().is_empty();
            }
            "--autostart" => app.autostart_pending = true,
            "--print-qemu-command" => print_command = true,
            "--help" | "-h" => {
                print!("{HELP}");
                return Startup::Exit;
            }
            "--version" => {
                println!("AccessibleUTM {}", env!("CARGO_PKG_VERSION"));
                return Startup::Exit;
            }
            _ => {
                eprintln!("ERROR: unknown option: {arg}");
                return Startup::Exit;
            }
        }
    }

    if !qemu_overridden {
        app.config.qemu_binary = default_qemu_binary(app.config.architecture);
    }

    if print_command {
        Startup::PrintCommand(app)
    } else {
        Startup::Gui(app)
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

impl AccessibleUtmApp {
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
            Err(error) => self.status = format!("Unable to query QEMU process state: {error}"),
        }
    }

    fn start_vm(&mut self) {
        self.refresh_process_state();
        if self.child.is_some() {
            self.status = "Virtual machine is already running.".to_owned();
            return;
        }
        if let Err(error) = validate_media(&self.config) {
            self.status = format!("Cannot start: {error}");
            return;
        }
        let args = match build_args(&self.config) {
            Ok(args) => args,
            Err(error) => {
                self.status = format!("Cannot start: {error}");
                return;
            }
        };
        let program = if self.config.qemu_binary.trim().is_empty() {
            default_qemu_binary(self.config.architecture)
        } else {
            self.config.qemu_binary.trim().to_owned()
        };
        let mut command = Command::new(&program);
        command
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        match command.spawn() {
            Ok(child) => {
                self.child = Some(child);
                self.status = format!(
                    "{} {} VM started. QMP is available locally on port {}.",
                    self.config.profile.label(),
                    self.config.architecture.label(),
                    self.config.qmp_port
                );
            }
            Err(error) => {
                self.status = format!("Unable to start QEMU using '{program}': {error}");
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
        let address = format!("127.0.0.1:{}", self.config.qmp_port);
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
            .map_err(|error| format!("Cannot flush QMP request: {error}"))?;
        let response = read_qmp_response(&mut reader)?;
        if let Some(error) = response.get("error") {
            return Err(format!("QMP capability negotiation failed: {error}"));
        }
        writeln!(writer, "{}", json!({"execute": command}))
            .map_err(|error| format!("Cannot send QMP command {command}: {error}"))?;
        writer
            .flush()
            .map_err(|error| format!("Cannot flush QMP command: {error}"))?;
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

    fn print_qemu_command(&mut self) {
        match printable_command(&self.config) {
            Ok(command) => {
                println!("{command}");
                self.status = "QEMU command printed to stdout.".to_owned();
            }
            Err(error) => self.status = format!("Cannot generate QEMU command: {error}"),
        }
    }

    fn save_configuration(&mut self) {
        match self.config.save(&self.config_path) {
            Ok(()) => {
                self.status = format!(
                    "Configuration saved to {}.",
                    self.config_path.display()
                )
            }
            Err(error) => self.status = error,
        }
    }

    fn load_configuration(&mut self) {
        match VmConfig::load(&self.config_path) {
            Ok(mut config) => {
                config.normalize();
                if config.qemu_binary.trim().is_empty() {
                    config.qemu_binary = default_qemu_binary(config.architecture);
                }
                self.config = config;
                self.status = format!(
                    "Configuration loaded from {}.",
                    self.config_path.display()
                );
            }
            Err(error) => self.status = error,
        }
    }

    fn handle_shortcuts(&mut self, ctx: &egui::Context) {
        let (
            start,
            pause,
            resume,
            graceful_shutdown,
            print_command,
            save_configuration,
            load_configuration,
        ) = ctx.input(|input| {
            (
                input.key_pressed(egui::Key::F5),
                input.key_pressed(egui::Key::F6),
                input.key_pressed(egui::Key::F7),
                input.key_pressed(egui::Key::F8),
                input.key_pressed(egui::Key::F9),
                input.modifiers.ctrl && input.key_pressed(egui::Key::S),
                input.modifiers.ctrl && input.key_pressed(egui::Key::O),
            )
        });

        if start {
            self.start_vm();
        }
        if pause {
            self.run_qmp_action("stop", "Virtual machine paused through QMP.");
        }
        if resume {
            self.run_qmp_action("cont", "Virtual machine resumed through QMP.");
        }
        if graceful_shutdown {
            self.run_qmp_action(
                "system_powerdown",
                "Graceful guest shutdown requested through QMP.",
            );
        }
        if print_command {
            self.print_qemu_command();
        }
        if save_configuration {
            self.save_configuration();
        }
        if load_configuration {
            self.load_configuration();
        }
    }

    fn render(&mut self, ui: &mut egui::Ui) {
        ui.heading("AccessibleUTM Windows");
        ui.label("Accessibility-first multi-architecture virtual machine manager");
        ui.separator();

        ui.heading("Guest profile");
        ui.horizontal_wrapped(|ui| {
            for profile in GuestProfile::ALL {
                ui.radio_value(&mut self.config.profile, profile, profile.label());
            }
        });

        ui.add_space(8.0);
        ui.heading("Architecture");
        let old_architecture = self.config.architecture;
        ui.horizontal_wrapped(|ui| {
            for architecture in Architecture::ALL {
                ui.radio_value(
                    &mut self.config.architecture,
                    architecture,
                    architecture.label(),
                );
            }
        });
        if old_architecture != self.config.architecture {
            let old_default = default_qemu_binary(old_architecture);
            if self.config.qemu_binary.trim().is_empty() || self.config.qemu_binary == old_default {
                self.config.qemu_binary = default_qemu_binary(self.config.architecture);
            }
        }

        if self.config.profile == GuestProfile::AccessibleAndroid
            && self.config.architecture == Architecture::X86_64
        {
            ui.label("AccessibleAndroid x86_64 integration active: OS disk remains pinned to PCI 0000:00:06.0 for Android first-stage init.");
        } else if self.config.profile == GuestProfile::AccessibleAndroid {
            ui.label("AccessibleAndroid non-x86 profile is experimental. The existing x86_64 ISO/disk contract is preserved unchanged.");
        }

        ui.add_space(12.0);
        ui.heading("Virtual machine configuration");
        egui::Grid::new("utm_vm_configuration_grid")
            .num_columns(2)
            .spacing([16.0, 10.0])
            .show(ui, |ui| {
                let label = ui.label("VM name");
                ui.text_edit_singleline(&mut self.config.name)
                    .labelled_by(label.id);
                ui.end_row();

                let label = ui.label("QEMU executable");
                ui.text_edit_singleline(&mut self.config.qemu_binary)
                    .on_hover_text("QEMU system executable for the selected guest architecture")
                    .labelled_by(label.id);
                ui.end_row();

                let label = ui.label("Boot ISO path");
                ui.text_edit_singleline(&mut self.config.iso_path)
                    .on_hover_text("AccessibleAndroid ISO or another bootable guest ISO")
                    .labelled_by(label.id);
                ui.end_row();

                let label = ui.label("Virtual disk path");
                ui.text_edit_singleline(&mut self.config.disk_path)
                    .on_hover_text("RAW, QCOW2, VDI, VMDK, VHD or VHDX disk")
                    .labelled_by(label.id);
                ui.end_row();

                let label = ui.label("Firmware path");
                ui.text_edit_singleline(&mut self.config.firmware_path)
                    .on_hover_text("Optional UEFI or architecture firmware image")
                    .labelled_by(label.id);
                ui.end_row();

                let label = ui.label("Memory");
                ui.add(
                    egui::Slider::new(&mut self.config.memory_mib, 1024..=65536)
                        .text("Memory in MiB")
                        .step_by(512.0),
                )
                .labelled_by(label.id);
                ui.end_row();

                let label = ui.label("Processors");
                ui.add(
                    egui::Slider::new(&mut self.config.cpu_count, 1..=32)
                        .text("Virtual processor count"),
                )
                .labelled_by(label.id);
                ui.end_row();

                let label = ui.label("QMP local port");
                ui.add(
                    egui::DragValue::new(&mut self.config.qmp_port)
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
                .add_enabled(!running, egui::Button::new("Start virtual machine (F5)"))
                .clicked()
            {
                self.start_vm();
            }
            if ui
                .add_enabled(running, egui::Button::new("Pause virtual machine (F6)"))
                .clicked()
            {
                self.run_qmp_action("stop", "Virtual machine paused through QMP.");
            }
            if ui
                .add_enabled(running, egui::Button::new("Resume virtual machine (F7)"))
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
                .add_enabled(
                    running,
                    egui::Button::new("Request graceful shutdown (F8)"),
                )
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

        ui.add_space(12.0);
        ui.heading("Configuration and diagnostics");
        ui.horizontal_wrapped(|ui| {
            if ui.button("Print QEMU command (F9)").clicked() {
                self.print_qemu_command();
            }
            if ui.button("Save configuration (Ctrl+S)").clicked() {
                self.save_configuration();
            }
            if ui.button("Load configuration (Ctrl+O)").clicked() {
                self.load_configuration();
            }
        });
        ui.label(format!(
            "Configuration file: {}",
            self.config_path.display()
        ));

        ui.add_space(16.0);
        ui.heading("Status");
        ui.label(&self.status);
        ui.add_space(12.0);
        ui.heading("Keyboard and screen-reader navigation");
        ui.label("All primary controls are keyboard reachable. Use Tab and Shift+Tab between controls, arrow keys for radio buttons/sliders, Enter or Space to activate actions, F5 through F9 for VM actions and diagnostics, Ctrl+S to save, and Ctrl+O to load. Windows UI Automation exposure is provided through the eframe/egui accessibility stack and is continuously smoke-tested on Windows runners; NVDA, JAWS and Narrator remain required for user-level screen-reader validation.");
    }
}

impl Drop for AccessibleUtmApp {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

impl eframe::App for AccessibleUtmApp {
    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.refresh_process_state();
        self.handle_shortcuts(ctx);
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
        Startup::PrintCommand(app) => match printable_command(&app.config) {
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
                "AccessibleUTM Windows",
                options,
                Box::new(move |creation_context| {
                    creation_context.egui_ctx.enable_accesskit();
                    Ok(Box::new(app))
                }),
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_names_round_trip() {
        for architecture in Architecture::ALL {
            assert_eq!(
                Architecture::from_cli(architecture.cli_name()),
                Some(architecture)
            );
        }
        for profile in GuestProfile::ALL {
            assert_eq!(GuestProfile::from_cli(profile.cli_name()), Some(profile));
        }
    }

    #[test]
    fn missing_config_path_is_accepted_for_first_save() {
        let mut app = AccessibleUtmApp::default();
        let path = PathBuf::from("definitely-does-not-exist-accessible-utm-test.json");
        assert!(load_cli_config(&mut app, &path).is_ok());
        assert_eq!(app.config_path, path);
    }
}
