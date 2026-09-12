# AccessibleUTM Windows

AccessibleUTM is the accessibility-first Windows frontend for the Accessible Virtual Suite. It drives QEMU directly and keeps the AccessibleAndroid x86_64 hardware contract stable while also supporting generic Linux and Windows guests plus experimental ARM64 and RISC-V profiles.

## Accessibility contract

- Native Windows UI Automation exposure is provided by `eframe`/`egui` through AccessKit.
- Every editable VM field is explicitly associated with a visible label.
- Primary VM actions are reachable with Tab/Shift+Tab and expose keyboard shortcuts.
- Status changes are exposed as a polite, atomic AccessKit live region so screen readers can announce VM state and error updates without moving focus.
- Hosted CI verifies the accessibility source contract and attempts a non-blocking UIA probe.
- Strict UIA tree and keyboard validation runs only in a real interactive Windows session; a GitHub-hosted desktop probe is never presented as equivalent evidence.

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

## Reproducible Rust dependencies

`accessible-utm/Cargo.lock` is committed. CI, self-hosted validation and the local accessibility gate all use Cargo `--locked`; a stale or missing lockfile is a hard failure instead of silently resolving a different dependency graph.

## Build

```powershell
cargo test --release --locked --manifest-path accessible-utm/Cargo.toml
cargo build --release --locked --manifest-path accessible-utm/Cargo.toml
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

### 1. Automated Rust and VM contract

`cargo test --locked` validates configuration serialization, AccessKit semantics and QEMU argument generation against the committed dependency graph. Hosted GitHub Actions additionally builds the release binary and verifies the AccessibleAndroid x86_64 contract plus ARM64 and RISC-V command generation.

### 2. Hosted Windows accessibility probe

The normal Windows workflow verifies that labels, named actions and keyboard shortcuts are present in the source contract. It also attempts the real UIA smoke test. Because GitHub-hosted Windows runners do not guarantee a usable interactive desktop/UIA provider, failure of that hosted runtime probe is classified as `UNVERIFIED`, not as a product accessibility PASS or FAIL.

The deterministic Windows ZIP is still built and verified byte-for-byte independently of that hosted UIA limitation.

### 3. Strict interactive UIA gate

For an actual signed-in Windows desktop, run from the repository root:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\accessible-utm\tests\windows_interactive_gate.ps1
```

This verifies the committed Cargo lockfile, performs the locked release Rust tests/build, launches the real GUI, inspects the Windows UI Automation tree, exercises the F9 keyboard path, records environment plus executable/Cargo.lock SHA-256 metadata, and creates an `AccessibleUTM-Evidence-*.zip` package on the desktop.

The same strict gate is available through the `AccessibleUTM UIA Interactive` GitHub workflow when a Windows x64 self-hosted runner is launched inside a signed-in interactive session rather than Session 0.

### 4. Screen-reader release gate

NVDA, JAWS and Narrator human-in-the-loop validation remains mandatory. Process detection by the evidence script only records which screen readers were running; it never counts as user validation. The release gate must confirm keyboard traversal, editable-field announcements, action names/shortcuts, status changes, focus behavior and a real QEMU guest workflow with each required screen reader.
