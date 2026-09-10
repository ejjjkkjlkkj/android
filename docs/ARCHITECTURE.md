# Architecture

## Product objective

Accessible Android is a phone-class AOSP distribution whose primary reference hardware is a virtual device. Accessibility is a boot-critical subsystem, not an optional post-install application.

## Base platform

- AOSP manifest: `android-latest-release`
- Current release family: Android 17
- Primary VM: Cuttlefish x86_64 phone
- Secondary VM: Cuttlefish ARM64 phone
- Build variant during development: `userdebug`
- Production hardening target: `user`

## Layers

### 1. Upstream AOSP

Synced directly from `https://android.googlesource.com/platform/manifest`. The source tree is kept outside this orchestration repository because AOSP contains hundreds of Git projects and very large build outputs.

### 2. Accessible product overlay

`vendor/accessibledroid/` is copied into the AOSP tree before the build. It owns product identity, accessibility defaults, packages, overlays, init hooks and release properties without rewriting unrelated AOSP projects.

### 3. Speech and screen reader

The release pipeline must provide:

1. a screen reader package built from auditable source;
2. an offline system TTS engine and at least one bundled voice;
3. first-boot configuration that makes speech available before Wi-Fi/account setup;
4. a safe mechanism to re-enable accessibility through ADB/keyboard if configuration is damaged.

Google's public TalkBack source is the initial compatibility reference. The distribution must never depend on Play Store availability to obtain its first screen reader.

### 4. Braille

Braille support is a release requirement. The implementation must support Android accessibility APIs and a path for HID/Bluetooth braille displays, with keyboard-based braille test coverage where physical hardware is unavailable in CI.

### 5. VM runtime

Cuttlefish is the canonical runtime because it is developed with AOSP and exposes a phone-class Android virtual device to `adb`. The release bundle must keep host tools and device images from the same build.

### 6. Generic VM target

After the Cuttlefish reference is stable, a separate target will package a generic x86_64 UEFI/QEMU/KVM image. VMware and VirtualBox compatibility are downstream targets and must not weaken the canonical Cuttlefish build.

## Release gates

A release candidate must pass, at minimum:

- boot-completed check;
- `adb` connectivity;
- PackageManager/APK installation smoke test;
- audio output presence;
- TTS engine enumeration and synthesis test;
- enabled accessibility service verification;
- keyboard focus traversal test;
- screen-reader event smoke test;
- braille service/input smoke test;
- reboot persistence;
- CTS plan for compatibility regressions;
- VTS/device-side tests appropriate to the target;
- accessibility regression suite.

## Non-goals

The project does not claim that an AOSP build is a Google-certified phone. GMS/Play certification and proprietary hardware blobs are separate licensing/certification tracks.