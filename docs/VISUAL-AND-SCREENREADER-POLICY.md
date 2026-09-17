# Visual + screen-reader accessibility policy

AccessibleAndroid follows an additive accessibility model: accessibility augments the visual interface; it does not replace it.

## Non-negotiable rule

Every project-controlled interactive stage must preserve a usable visual interface while exposing the same actions and state through accessible input/output paths.

Required parallel paths:

- **Visual:** visible boot menu, visible installer state, visible Android UI.
- **Screen reader / speech:** spoken equivalent of actionable state and important status changes.
- **Keyboard:** full operation without requiring a pointer.
- **Braille/serial where available:** additional equivalent output paths, never substitutes for the normal visual UI.

## Bootloader

GRUB must keep its normal visible menu. Speech-oriented cues, hotkeys and serial mirroring are additional channels. The visible menu must not be hidden merely because an accessible automatic path exists.

## Installer

The installer must display each page/state on screen and expose the same state to Speakup/eSpeak. Selection, warnings, progress, errors and confirmations must be both visible and available to the screen-reader path. Destructive actions require explicit confirmation.

## Android

Android must retain its standard graphical interface. TalkBack, offline TTS, keyboard navigation, accessibility shortcuts and braille support are accessibility layers over that UI. TalkBack must be possible to enable immediately, but the graphical UI must remain fully present for sighted and low-vision users.

## Validation rule

A build is invalid if accessibility is implemented by removing, hiding or bypassing the normal visual interface. The expected result is one interface with equivalent visual and non-visual access paths.
