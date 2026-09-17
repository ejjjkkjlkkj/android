# Accessible installer layer

This directory will contain the Buildroot external tree used to generate the installer kernel and initramfs.

The installer is **not speech-only**. It must preserve a visible text/TUI interface while exposing the same state and actions through screen-reader speech and keyboard access.

Target behavior:

- visible x86_64 text/TUI installer;
- x86_64 kernel with Speakup and software-synth support;
- eSpeak NG + espeakup started as early as audio becomes available;
- serial console mirror at 115200 baud;
- complete keyboard operation;
- optional BRLTTY support;
- target-disk identity both displayed and spoken before any write;
- explicit confirmation before partitioning, both visible and screen-reader accessible;
- installation progress, warnings and errors both displayed and announced/exposed to the speech path;
- SHA-256 verification of every Android payload image;
- recovery mode that performs no disk writes;
- no accessibility option may disable or replace the normal visible installer state.

The installer environment is separate from Android. Its sole purpose is to provide a deterministic installation path with equivalent visual and non-visual access, then install the Android payload and boot configuration to the target disk.
