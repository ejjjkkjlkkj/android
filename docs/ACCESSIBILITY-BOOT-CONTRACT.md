# Accessible boot contract

The project is not considered successful merely because Android eventually boots. Accessibility must be continuous across the boot and installation path wherever the project controls the software.

## 0. Firmware boundary

The project controls the ISO only after BIOS/UEFI transfers execution to it. There is no portable UEFI speech API that lets an ISO universally make firmware setup, firmware boot pickers or Secure Boot enrollment dialogs speak. The project therefore minimizes the need to interact with firmware: the ISO must boot automatically when selected and must not require a visual boot menu choice.

## 1. GRUB accessibility gate

The ISO bootloader must:

- boot the accessible installer automatically after a short timeout;
- accept keyboard-only control;
- expose single-key menu hotkeys;
- emit distinct GRUB `play` tone patterns when the platform exposes the required speaker path;
- mirror text input/output to serial at 115200 baud when serial is available;
- keep console output active together with serial output;
- provide a recovery entry that never requires graphics;
- never require pointer input, color recognition or timed visual interaction.

Tones are an enhancement, not the only feedback mechanism. Many UEFI VMs do not expose a PC speaker, so the installer must become genuinely speech-enabled after the Linux kernel starts.

## 2. Installer speech gate

The installer Linux kernel/rootfs must provide:

- `CONFIG_SPEAKUP=y` or equivalent built-in availability;
- `CONFIG_SPEAKUP_SYNTH_SOFT=y` or a guaranteed early-loaded module;
- `/dev/softsynth` availability;
- eSpeak NG and espeakup in the initramfs/rootfs;
- ALSA userspace and drivers for common virtual audio devices where practical;
- `tty0` plus `ttyS0,115200` console paths;
- an explicit audible announcement when speech starts;
- a no-speech serial fallback that exposes the same installer state;
- keyboard-only navigation;
- optional BRLTTY support for braille displays when USB/serial transport is available.

The installer must not silently continue destructive disk operations without a keyboard confirmation and a spoken/serial description of the selected target disk.

## 3. Android accessibility gate

Android 17 must ship with:

- a preinstalled screen reader derived from the pinned open-source TalkBack source;
- offline eSpeak NG TTS;
- an accessibility bootstrap capable of enabling TalkBack and selecting the offline TTS at first boot;
- Direct Boot compatibility for the preinstalled accessibility bootstrap path;
- hardware-keyboard navigation and accessibility shortcuts;
- braille support supplied by TalkBack where supported;
- no dependency on Google Mobile Services for basic speech accessibility.

The build must verify the TalkBack APK itself. Current upstream TalkBack constrains native ABIs to ARM in its shared Gradle configuration, so this project must patch/build and then inspect the APK to prove that any required native libraries are available for x86_64. A successful Gradle exit code alone is not sufficient.

## 4. ISO gate

The final artifact is:

`out/iso/AccessibleAndroid-17-x86_64-BIOS-UEFI.iso`

The ISO must contain:

- BIOS and x86_64 UEFI boot paths;
- GRUB configuration and modules needed by the selected boot paths;
- the accessible installer kernel and initramfs/rootfs;
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
4. GRUB config contains automatic boot, serial mirroring and accessible installer entry;
5. installer kernel configuration enables Speakup software synthesis;
6. installer rootfs contains eSpeak NG/espeakup and audio utilities;
7. Android images required by the installer exist and are non-empty;
8. TalkBack package/service identities are correct;
9. TalkBack/eSpeak APK native payloads are compatible with x86_64 or contain no incompatible mandatory native code;
10. the ISO exposes `/EFI/BOOT/BOOTX64.EFI` and a BIOS boot image;
11. SHA-256 checksums are generated and verified;
12. the final result contains no `.qcow2`, `.vdi`, `.vmdk` or VM configuration artifact.

The final pass criterion is accessibility evidence, not only compilation success.
