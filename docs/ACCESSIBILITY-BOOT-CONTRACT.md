# Accessible boot contract

The project is not considered successful merely because Android eventually boots. Accessibility must be continuous across the boot and installation path wherever the project controls the software.

The governing principle is **visual + accessible parity**: accessibility augments the normal visual interface and must never replace it. Each project-controlled interactive state must remain visibly usable while also exposing equivalent state and actions through screen-reader speech and keyboard access.

## 0. Firmware boundary

The project controls the ISO only after BIOS/UEFI transfers execution to it. Firmware setup screens, firmware boot pickers and Secure Boot enrollment dialogs are outside the ISO's control. The project minimizes required firmware interaction but does not alter or replace firmware visuals.

## 1. GRUB accessibility gate

The ISO bootloader must:

- keep a normal visible GRUB menu;
- boot the accessible installer automatically after a short timeout while still showing the menu during that timeout;
- accept keyboard-only control;
- expose single-key menu hotkeys;
- emit distinct GRUB `play` tone patterns when the platform exposes the required speaker path;
- mirror text input/output to serial at 115200 baud when serial is available;
- keep local visual console output active together with serial output;
- provide a recovery entry visible in the normal menu and reachable without pointer input;
- never require color recognition, pointer input or timed visual interaction for essential actions.

Tones, serial and hotkeys are additional accessibility channels. They do not replace the visible GRUB menu.

## 2. Installer visual + screen-reader gate

The installer Linux kernel/rootfs must provide:

- a visible text/TUI installer interface;
- `CONFIG_SPEAKUP=y` or equivalent built-in availability;
- `CONFIG_SPEAKUP_SYNTH_SOFT=y` or a guaranteed early-loaded module;
- `/dev/softsynth` availability;
- eSpeak NG and espeakup in the initramfs/rootfs;
- ALSA userspace and drivers for common virtual audio devices where practical;
- `tty0` plus `ttyS0,115200` console paths;
- an explicit audible announcement when speech starts;
- serial fallback exposing the same installer state;
- complete keyboard navigation;
- optional BRLTTY support for braille displays when USB/serial transport is available.

Every installer state that changes what the user can do must be both **displayed** and **available to the screen-reader path**. This includes target-disk identity, selections, warnings, progress, failures and confirmations.

The installer must not silently continue destructive disk operations without explicit keyboard confirmation and a description that is both visible and spoken/serial-exposed.

## 3. Android accessibility gate

Android 17 must retain its normal graphical interface and ship with:

- a preinstalled screen reader derived from the pinned open-source TalkBack source;
- offline eSpeak NG TTS;
- an accessibility bootstrap capable of making TalkBack and the offline TTS available immediately at first boot;
- Direct Boot compatibility for the preinstalled accessibility bootstrap path;
- hardware-keyboard navigation and accessibility shortcuts;
- braille support supplied by TalkBack where supported;
- no dependency on Google Mobile Services for basic speech accessibility.

TalkBack is an accessibility layer over Android's graphical UI. The graphical UI must not be removed, hidden or replaced by a speech-only shell.

The build must verify the TalkBack APK itself and prove compatibility with x86_64 for any mandatory native code. A successful Gradle exit code alone is not sufficient.

## 4. ISO gate

The final artifact is:

`out/iso/AccessibleAndroid-17-x86_64-BIOS-UEFI.iso`

The ISO must contain:

- BIOS and x86_64 UEFI boot paths;
- GRUB configuration and modules needed by the selected boot paths;
- a visible GRUB menu plus parallel accessibility channels;
- the installer kernel and initramfs/rootfs;
- a visible installer UI plus screen-reader support;
- Android installation payload images;
- payload SHA-256 manifest;
- source/version manifest;
- an installer log path that can be copied after failure;
- no VM disk image and no VM definition.

## 5. Required validation evidence

Before an ISO is called final, CI/local validation must prove:

1. all shell scripts parse and pass ShellCheck at error/warning severity;
2. every pinned source variable is non-empty and immutable for the build;
3. Buildroot archive SHA-256 matches the pinned value;
4. GRUB keeps a visible menu and also contains serial mirroring, hotkeys and the accessible installer entry;
5. installer kernel configuration enables Speakup software synthesis;
6. installer rootfs contains eSpeak NG/espeakup and audio utilities;
7. installer states are visibly rendered and exposed through the screen-reader path;
8. Android images required by the installer exist and are non-empty;
9. TalkBack package/service identities are correct;
10. TalkBack/eSpeak APK native payloads are compatible with x86_64 or contain no incompatible mandatory native code;
11. the ISO exposes `/EFI/BOOT/BOOTX64.EFI` and a BIOS boot image;
12. SHA-256 checksums are generated and verified;
13. the final result contains no `.qcow2`, `.vdi`, `.vmdk` or VM configuration artifact;
14. no accessibility mode removes or suppresses the normal visual interface.

The final pass criterion is equivalent access through visual and non-visual paths, not compilation success alone.
