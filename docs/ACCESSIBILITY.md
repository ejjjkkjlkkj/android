# Blind-first accessibility contract

This document defines release requirements for a blind user. A build that boots visually but cannot be operated independently does not pass.

## A. First boot

The user must be able to complete initial setup without a mouse and without sight.

Required:

- audio stack ready before Setup Wizard interaction;
- offline TTS engine present locally;
- at least one local voice preinstalled;
- screen reader service installed in the system image;
- documented keyboard shortcut and ADB recovery path to enable the service;
- first-run UI exposes meaningful accessibility labels, roles, state and focus order;
- network access must not be required for initial speech.

## B. Screen reader

The reference implementation is TalkBack-compatible Android AccessibilityService behavior.

Required coverage:

- focus navigation;
- activation/click;
- headings and controls;
- editable text;
- lists and grids;
- notifications;
- dialogs;
- quick settings;
- launcher;
- Settings;
- web content through the Android accessibility stack;
- volume and speech controls;
- global Back, Home, Recents and Notifications actions.

## C. Keyboard

Every release must be usable with a standard host keyboard through the VM.

Minimum keys tested:

- Tab / Shift+Tab;
- arrows;
- Enter / Space;
- Escape/Back mapping;
- Home and system navigation mappings;
- text input including accents;
- screen-reader shortcut mappings.

No critical first-boot action may require pointer-only interaction.

## D. Speech

Speech is considered boot-critical.

Required:

- offline operation;
- deterministic default locale fallback;
- adjustable rate and pitch;
- route through Android AudioManager;
- recovery if the preferred engine crashes;
- smoke test that synthesizes a known phrase and verifies successful engine completion.

French and English are priority languages for the initial release.

## E. Braille

Target capabilities:

- braille display discovery/connection where virtual or physical transport permits it;
- braille output routing;
- braille keyboard/input path;
- contracted/uncontracted table architecture;
- French and English validation;
- deterministic CI test doubles for cases where hardware is unavailable.

## F. Host accessibility

The VM launcher and tooling must also be accessible from Windows/Linux/macOS hosts where supported:

- command-line first;
- no required drag-and-drop;
- meaningful exit codes;
- plain-text logs;
- no status communicated only by color/animation;
- Web UI, when used, is secondary rather than required.

## G. Recovery

A blind user or support technician must be able to recover speech without reinstalling the VM.

Required recovery commands are implemented in `scripts/accessibility-recovery.sh` and must verify the resulting secure settings instead of assuming success.

## H. Automated acceptance

A release must fail when any critical accessibility prerequisite is absent. The initial automated gate checks boot state, audio service, TTS registration, accessibility service registration/enabled state, package presence and persistence after reboot. UI-level event tests are added as the custom product matures.

## I. Runtime verification and recovery

After Android reaches `sys.boot_completed=1`, validate the actual guest state through ADB:

```bash
bash scripts/verify-accessibility-runtime-adb.sh
```

For a non-default ADB target, set `ADB_SERIAL` first. The validator fails unless TalkBack and eSpeak are installed, TalkBack is registered, enabled, and actually bound to AccessibilityManagerService, Android accessibility is enabled, eSpeak is the configured default TTS engine, AudioService and AudioFlinger are available, and offline eSpeak successfully completes deterministic English and French synthesis.

To recover speech settings without reinstalling the VM:

```bash
bash scripts/accessibility-recovery.sh
```

The recovery script preserves any other enabled accessibility services, adds TalkBack only when missing, selects offline eSpeak, and then runs the same runtime validator before reporting PASS.


A runtime release proof must include `TALKBACK_BOUND = PASS`, `TTS_SYNTHESIS_EN_US = PASS`, `TTS_SYNTHESIS_FR_FR = PASS`, and `ACCESSIBILITY_RUNTIME = PASS`. Package presence or secure settings alone are not sufficient.
