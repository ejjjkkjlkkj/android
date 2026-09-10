# Accessible Android

Android 17 AOSP distribution designed accessibility-first for blind users.

## Goal

Build a complete Android phone-class virtual device that can be used without sight from the first boot:

- screen reader available and enabled during first-run setup;
- offline text-to-speech fallback before network configuration;
- keyboard-only operation from the host;
- braille input/output path;
- spoken boot/readiness status;
- audio, networking, storage and Android app installation;
- phone-class Cuttlefish device profile;
- automated accessibility smoke tests plus CTS/VTS compatibility gates;
- reproducible x86_64 VM artifacts first, ARM64 second;
- later generic QEMU/KVM image and physical-device targets.

## Current upstream

The build follows the AOSP `android-latest-release` manifest. As of September 2026 this resolves to the Android 17 release family.

Primary reference target:

```text
aosp_cf_x86_64_only_phone-userdebug
```

ARM64 reference target:

```text
aosp_cf_arm64_only_phone-userdebug
```

## Important scope boundary

This repository builds an open AOSP distribution. Google Mobile Services, Google Play Store, proprietary Pixel firmware and other licensed Google binaries are not part of AOSP and are not silently redistributed here. APK installation and Android framework compatibility remain core targets.

## Architecture

This repository is the distribution/orchestration layer. AOSP itself is synchronized from Google's official manifest rather than copied into this Git repository.

```text
android/
├── config/                 upstream and product configuration
├── docs/                   architecture, accessibility contract, roadmap
├── scripts/                host bootstrap, source sync, build and validation
├── vendor/accessibledroid/ AOSP product overlay injected into the source tree
└── .github/workflows/      lightweight CI and self-hosted full-build gates
```

## First build

A full AOSP build requires a Linux host with hardware virtualization and substantial RAM/disk. On the build host:

```bash
./scripts/bootstrap-host.sh
./scripts/sync-aosp.sh
./scripts/install-overlay.sh
./scripts/build-cuttlefish.sh
```

The generated Android images stay in the AOSP output tree. The packaging phase will produce a versioned Accessible Android VM bundle containing the matching Cuttlefish host package and device images.

## Accessibility definition of done

A release is not accepted merely because Android boots. It must satisfy the contract in `docs/ACCESSIBILITY.md`, including a no-mouse first boot, working speech without network, TalkBack-compatible navigation, braille path, recovery path, and automated checks.

## Status

Bootstrap phase: repository architecture and Android 17/Cuttlefish build pipeline are being established.