# Accessible installer layer

This directory will contain the Buildroot external tree used to generate the installer kernel and initramfs.

Target behavior:

- x86_64 kernel with Speakup and software-synth support;
- eSpeak NG + espeakup started as early as audio becomes available;
- serial console mirror at 115200 baud;
- keyboard-only installer state machine;
- optional BRLTTY support;
- target-disk identity spoken and printed before any write;
- explicit confirmation before partitioning;
- SHA-256 verification of every Android payload image;
- recovery mode that performs no disk writes.

The installer environment is separate from Android. Its sole purpose is to make the installation path accessible and deterministic, then install the Android payload and boot configuration to the target disk.
