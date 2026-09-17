# AccessibleAndroid — Android 17 x86_64 ISO accessible from boot to Android

This branch is a clean rebuild focused on one deliverable: a bootable **x86_64 BIOS/UEFI installer ISO** for Android 17 that is as accessible as technically possible before, during and after installation.

No VM is created or started by this project. The ISO is intended to be mounted later in Hyper-V, QEMU, UTM, VirtualBox or another x86_64 virtual machine.

## Accessibility chain

1. **Firmware hand-off** — the ISO starts at the point where BIOS/UEFI gives control to the boot medium. Firmware setup screens are outside the ISO's control and cannot be made universally speech-enabled by the project.
2. **GRUB 2.14** — automatic accessible boot, keyboard hotkeys, audible tone cues when supported, mirrored serial console, no visual selection required.
3. **Accessible installer Linux** — Buildroot-based x86_64 installer with Linux Speakup, `speakup_soft`, eSpeak NG + espeakup, ALSA, serial fallback and optional BRLTTY.
4. **Android payload installation** — integrity-checked Android images are installed to the target disk by a keyboard-only, speech-first workflow.
5. **Android first boot** — TalkBack, offline eSpeak NG TTS and an accessibility bootstrap are preinstalled. The build must prove x86_64 native compatibility and must not silently ship ARM-only TalkBack native libraries.

## Pinned baseline

- Android 17 / API 37: `android-security-17.0.0_r1`
- Android kernel: `android17-6.18-2026-09_r3`
- Buildroot: `2026.08`
- GRUB: `2.14`
- TalkBack: pinned source commit in `config/versions.env`
- eSpeak NG / espeakup: pinned source commits in `config/versions.env`

## Final artifact

`out/iso/AccessibleAndroid-17-x86_64-BIOS-UEFI.iso`

The final ISO must include checksums and evidence proving BIOS/UEFI boot files, installer speech components, Android images, TalkBack, offline TTS and x86_64 ABI checks.

See `docs/ACCESSIBILITY-BOOT-CONTRACT.md` for the non-negotiable accessibility gates.
