# GitHub recovery and resume status

Date: 2026-09-13

The active development line is `fix/queue-android-final-builds-20260913`.

Current recovery strategy:

- preserve any divergent self-hosted runner commit before checkout;
- use the persistent `.work/aosp` workspace when available;
- build with conservative parallelism on the current WSL builder;
- complete the Android 17 AOSP build;
- create the preinstalled BIOS/UEFI disk;
- validate boot through QEMU;
- upload recovery data, build logs, manifests and hashes as GitHub Actions evidence.

Promotion to `main` should occur only after the self-hosted recovery/resume workflow has completed successfully or after its remaining failures have been diagnosed and fixed.
