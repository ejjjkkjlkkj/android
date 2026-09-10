use eframe::egui;
use std::env;
use std::path::Path;
use std::process::{Child, Command, Stdio};

struct AccessibleQemuApp {
    qemu_binary: String,
    iso_path: String,
    disk_path: String,
    memory_mib: u32,
    cpu_count: u32,
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

fn app_from_args() -> AccessibleQemuApp {
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
            "--autostart" => app.autostart_pending = true,
            "--help" | "-h" => {
                println!(
                    "AccessibleQEMU\n\nOptions:\n  --iso <path>       AccessibleAndroid ISO\n  --disk <path>      QCOW2 virtual disk\n  --qemu <path>      qemu-system-x86_64 executable\n  --memory <MiB>     Guest memory, 1024..32768\n  --cpus <count>     Guest virtual CPUs, 1..16\n  --autostart        Start VM immediately after opening GUI\n"
                );
            }
            _ => {}
        }
    }

    app
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
                self.status = format!("Unable to query QEMU state: {error}");
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
                self.status = "Virtual machine started. QEMU is running.".to_owned();
            }
            Err(error) => {
                self.status = format!(
                    "Unable to start QEMU using '{}': {error}",
                    self.qemu_binary.trim()
                );
            }
        }
    }

    fn stop_vm(&mut self) {
        let Some(mut child) = self.child.take() else {
            self.status = "Virtual machine is already stopped.".to_owned();
            return;
        };

        match child.kill() {
            Ok(()) => {
                let _ = child.wait();
                self.status = "Virtual machine stopped.".to_owned();
            }
            Err(error) => {
                self.status = format!("Unable to stop QEMU: {error}");
                self.child = Some(child);
            }
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
                ui.label("QEMU executable");
                ui.text_edit_singleline(&mut self.qemu_binary)
                    .on_hover_text("Path or command name for qemu-system-x86_64");
                ui.end_row();

                ui.label("Android ISO path");
                ui.text_edit_singleline(&mut self.iso_path)
                    .on_hover_text("Path to the Accessible Android bootable ISO");
                ui.end_row();

                ui.label("Virtual disk path");
                ui.text_edit_singleline(&mut self.disk_path)
                    .on_hover_text("Path to an existing QCOW2 virtual disk");
                ui.end_row();

                ui.label("Memory");
                ui.add(
                    egui::Slider::new(&mut self.memory_mib, 1024..=32768)
                        .text("Memory in MiB")
                        .step_by(512.0),
                );
                ui.end_row();

                ui.label("Processors");
                ui.add(
                    egui::Slider::new(&mut self.cpu_count, 1..=16)
                        .text("Virtual processor count"),
                );
                ui.end_row();
            });

        ui.add_space(16.0);
        ui.heading("Virtual machine controls");
        ui.horizontal_wrapped(|ui| {
            if ui
                .add_enabled(
                    self.child.is_none(),
                    egui::Button::new("Start virtual machine"),
                )
                .clicked()
            {
                self.start_vm();
            }

            if ui
                .add_enabled(
                    self.child.is_some(),
                    egui::Button::new("Stop virtual machine"),
                )
                .clicked()
            {
                self.stop_vm();
            }

            if ui.button("Refresh status").clicked() {
                self.refresh_process_state();
                if self.child.is_some() {
                    self.status = "Virtual machine is running.".to_owned();
                } else if !self.status.starts_with("Unable") {
                    self.status = "Virtual machine is stopped.".to_owned();
                }
            }
        });

        ui.add_space(16.0);
        ui.heading("Status");
        ui.label(&self.status);

        ui.add_space(16.0);
        ui.heading("Keyboard navigation");
        ui.label(
            "Use Tab and Shift+Tab to move between controls, arrow keys to adjust sliders, and Enter or Space to activate the focused control.",
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
    let app = app_from_args();
    let options = eframe::NativeOptions::default();
    eframe::run_native(
        "AccessibleQEMU",
        options,
        Box::new(move |_creation_context| Ok(Box::new(app))),
    )
}
