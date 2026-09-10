# Accessible Android VM

Android 17 based x86_64 operating system designed to be installed and used inside a virtual machine, with accessibility for blind users treated as a boot-critical feature.

## Target

This project is **not ChromeOS** and is **not only an Android emulator**.

The primary deliverable is a real Android PC/VM distribution:

- bootable x86_64 ISO;
- BIOS and UEFI boot;
- live mode plus installation to a virtual disk;
- persistent `/data` partition;
- QEMU/KVM reference support;
- VirtualBox and VMware compatibility targets;
- qcow2, VDI and VMDK images generated from the installed reference image;
- Android APK installation;
- audio, network, keyboard, mouse/touch emulation, storage and clipboard integration where supported;
- accessibility available from first boot.

## Android base

- upstream platform: AOSP `android-latest-release`;
- current family: Android 17 / API 37;
- kernel reference: Android 17 GKI 6.18;
- architecture: x86_64 first;
- PC enablement: a maintained Android-x86/Android-Generic style BSP layer adapted to Android 17 rather than shipping an old Android-x86 release.

Android-x86's old public ISO releases are useful as implementation references for PC boot/install, but they are not used as the final Android base.

## Accessibility-first requirements

A release cannot ship unless a blind user can start and operate it without sight:

- screen reader installed in the system image;
- offline TTS engine and voice available before network setup;
- spoken first-boot flow;
- keyboard-only setup and navigation;
- braille input/output path;
- accessible installer with spoken status and non-destructive defaults;
- recovery shortcut to restore speech;
- audio and accessibility regression tests on every release image.

See `docs/ACCESSIBILITY.md`.

## Planned output

```text
AccessibleAndroid-17-x86_64.iso
AccessibleAndroid-17-x86_64.qcow2
AccessibleAndroid-17-x86_64.vdi
AccessibleAndroid-17-x86_64.vmdk
SHA256SUMS
build-manifest.json
```

## Build model

AOSP is too large to vendor directly into this small Git repository. This repository contains the manifest/orchestration, PC device layer, installer, accessibility overlay and CI. Build hosts synchronize the upstream Android source and then apply this distribution layer.

```text
android/
├── config/                 version and build configuration
├── docs/                   architecture and accessibility contract
├── installer/              boot/install environment
├── scripts/                source, build, packaging and VM validation
├── vendor/accessibledroid/ product and accessibility overlay
└── .github/workflows/      CI and large self-hosted builds
```

## Build direction

The PC image must expose a real `iso_img`-style build product and boot independently of Android Studio. Cuttlefish remains useful only as an upstream framework test reference; it is no longer the final deliverable.

## Status

Architecture pivoted to an installable Android 17 x86_64 VM OS. The next implementation milestone is the Android 17 PC BSP + ISO boot chain, followed by the spoken installer and VM compatibility matrix.