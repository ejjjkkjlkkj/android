# AccessibleAndroid — Android 17 x86_64 ISO accessible from boot to Android

This branch is a clean rebuild focused on one deliverable: a bootable **x86_64 BIOS/UEFI installer ISO** for Android 17 that preserves the normal visual experience while adding the strongest practical screen-reader accessibility before, during and after installation.

No VM is created or started by this project. The ISO is intended to be mounted later in Hyper-V, QEMU, UTM, VirtualBox or another x86_64 virtual machine.

## Core rule

**Accessibility is additive, not a replacement for the visual interface.** Every project-controlled stage must keep visible menus, visible installer state and the normal Android graphical UI while exposing equivalent access through screen-reader speech, keyboard navigation and, where available, braille/serial output.

## Accessibility chain

1. **Firmware hand-off** — the ISO starts at the point where BIOS/UEFI gives control to the boot medium. Firmware setup screens are outside the ISO's control.
2. **GRUB 2.14** — visible boot menu retained, plus keyboard hotkeys, audible tone cues when supported and mirrored serial output. No visual-only interaction is required.
3. **Accessible installer Linux** — visible text/TUI installer plus Linux Speakup, `speakup_soft`, eSpeak NG + espeakup, ALSA, keyboard navigation, serial fallback and optional BRLTTY.
4. **Android payload installation** — integrity-checked Android images are installed through a workflow whose selections, progress, warnings and confirmations are both visible and exposed to the screen-reader path.
5. **Android first boot** — standard Android graphical UI retained, with TalkBack, offline eSpeak NG TTS and an accessibility bootstrap available immediately. The build must prove x86_64 native compatibility and must not silently ship ARM-only mandatory native libraries.

## Pinned baseline

- Android 17 / API 37: `android-security-17.0.0_r1`
- Android kernel: `android17-6.18-2026-09_r3`
- Buildroot: `2026.08`
- GRUB: `2.14`
- TalkBack: pinned source commit in `config/versions.env`
- eSpeak NG / espeakup: pinned source commits in `config/versions.env`

## Final artifact

`out/iso/AccessibleAndroid-17-x86_64-BIOS-UEFI.iso`

The final ISO must include checksums and evidence proving BIOS/UEFI boot files, visible boot/install paths, installer speech components, Android images, TalkBack, offline TTS and x86_64 ABI checks.

See `docs/ACCESSIBILITY-BOOT-CONTRACT.md` and `docs/VISUAL-AND-SCREENREADER-POLICY.md` for the non-negotiable accessibility gates.
