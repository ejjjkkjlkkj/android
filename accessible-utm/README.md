# AccessibleUTM Windows

AccessibleUTM is the accessibility-first Windows frontend for the Accessible Virtual Suite. It drives QEMU directly and keeps the AccessibleAndroid x86_64 hardware contract stable while also supporting generic Linux and Windows guests plus experimental ARM64 and RISC-V profiles.

## Accessibility contract

- Native Windows UI Automation exposure is provided by `eframe`/`egui` through AccessKit.
- Every editable VM field is explicitly associated with a visible label.
- Primary VM actions are reachable with Tab/Shift+Tab and expose keyboard shortcuts.
- Status changes are rendered as readable text for screen readers.
- CI includes a Windows UI Automation smoke test in addition to Rust tests and QEMU command-contract tests.

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| F5 | Start virtual machine |
| F6 | Pause through QMP |
| F7 | Resume through QMP |
| F8 | Request graceful shutdown through QMP |
| F9 | Print the generated QEMU command |
| Ctrl+S | Save the current JSON configuration |
| Ctrl+O | Reload the current JSON configuration |

Force stop and reset intentionally require explicit button activation to reduce accidental destructive actions.

## Requirements

- Windows 11 x64.
- QEMU available on `PATH` or installed under `C:\Program Files\qemu`.
- WHPX / Windows Hypervisor Platform is preferred for x86_64 guests; QEMU falls back to TCG when WHPX is unavailable.

## Build

```powershell
cargo test --release --manifest-path accessible-utm/Cargo.toml
cargo build --release --manifest-path accessible-utm/Cargo.toml
```

The executable is written to `accessible-utm\target\release\accessible-utm.exe`.

## Examples

Show help:

```powershell
.\accessible-utm.exe --help
```

Open the AccessibleAndroid profile:

```powershell
.\accessible-utm.exe --profile accessible-android --arch x86_64 --iso C:\VM\AccessibleAndroid.iso --disk C:\VM\AccessibleAndroid.qcow2
```

Print the exact QEMU command without starting a VM:

```powershell
.\accessible-utm.exe --profile accessible-android --arch x86_64 --disk C:\VM\AccessibleAndroid.qcow2 --print-qemu-command
```

Use a persistent configuration file:

```powershell
.\accessible-utm.exe --config C:\VM\accessible-utm.json
```

If the file exists, it is loaded before command-line overrides are applied. In the GUI, use **Save configuration (Ctrl+S)** and **Load configuration (Ctrl+O)**.

## AccessibleAndroid x86_64 hardware contract

The Android profile preserves these fixed devices because Android early boot depends on them:

- OS disk: `virtio-blk-pci` at PCI `0000:00:06.0`
- RNG: `virtio-rng-pci` at PCI `0000:00:07.0`
- Network: `virtio-net-pci` at PCI `0000:00:08.0`
- Graphics: `virtio-vga`
- Input: xHCI + USB keyboard + absolute USB tablet
- Audio: host audio backend + `virtio-sound-pci`

## Validation levels

`cargo test` validates configuration serialization and QEMU argument generation. The GitHub Actions Windows job additionally builds the release binary, validates x86_64/ARM64/RISC-V command generation, starts the real GUI, inspects its Windows UI Automation tree, injects the F9 keyboard shortcut, and packages a versioned ZIP with SHA-256 metadata.

NVDA, JAWS and Narrator human-in-the-loop validation on a real Windows desktop remains a separate release gate; CI UI Automation is not presented as a substitute for those screen-reader passes.
