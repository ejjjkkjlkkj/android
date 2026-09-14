# GitHub recovery and resume status

Date: 2026-09-14

The active development line is `fix/queue-android-final-builds-20260913`.

Current recovery strategy:

- preserve the persistent `.work/aosp`, kernel and accessibility workspaces;
- reuse verified kernel and TalkBack/eSpeak build outputs when their fingerprints match;
- keep the Android 17 guest strictly x86_64-only through AOSP `core_64_bit_only.mk` and no `TARGET_2ND_ARCH`;
- fail before expensive Soong analysis if the resolved build configuration restores a secondary x86 architecture;
- stop Gradle daemons before Soong, cap AOSP build parallelism to `-j2` on the 31 GiB WSL builder and provide guarded swap headroom;
- capture RAM, PSI memory pressure, active swap and disk space before Soong;
- complete the Android 17 AOSP image build;
- create the deterministic 16 GiB preinstalled BIOS/UEFI GPT disk;
- validate full guest boot, accessibility stack and VM hardware through QEMU;
- verify the final QCOW2 and hashes;
- upload recovery data, build logs, manifests and hashes as GitHub Actions evidence.

Runner recovery:

- `scripts/start-android-build-runner.ps1` and `scripts/start-android-build-runner.sh` start the already configured runner without registering or removing it;
- both launchers treat `Runner.Listener` as the healthy process and do not mistake an orphan `Runner.Worker` for a live runner;
- the Linux launcher now attempts `svc.sh start` even when `svc.sh status` is non-zero, which correctly handles an installed but stopped service;
- when `gh` is authenticated, the launchers can report whether GitHub sees the runner online and expose its labels, including `android-build`;
- `scripts/install-android-build-runner-service.sh` can explicitly install that existing runner as the official Linux systemd service using `svc.sh`, then start it and verify a stable `Runner.Listener`;
- the service installer never runs automatically from CI and never uses a registration/removal token;
- on Debian it applies the GitHub-recommended `needrestart` exclusion for `actions.runner.*.service` when `needrestart` is present;
- the runner launcher/service contracts, PowerShell parse, Bash parse and repository ShellCheck all pass on head `0955051bd2c0db11f6e95b1901cb88edd5b0592f`.

Evidence from the latest completed real build attempt:

- runner: 31 GiB RAM, 12 CPUs, Debian under WSL2;
- AOSP sync: PASS;
- Android 17 / kernel 6.18 x86_64: PASS;
- kernel dist cache and 45 VM modules: PASS;
- TalkBack package/service/x86_64 native libraries: PASS;
- eSpeak NG TTS package/service/x86_64 native library: PASS;
- failure occurred during a single `soong_build` graph-analysis process after severe memory stalls, ending with signal 9 / exit 137;
- that attempt still had `TARGET_2ND_ARCH=x86`, so the branch now removes the unnecessary 32-bit native graph in addition to the memory protections.

Hosted validation on `0955051bd2c0db11f6e95b1901cb88edd5b0592f`:

- 9/9 PR workflows: PASS;
- `Validate repository`: PASS, including Bash parse and ShellCheck;
- `Validate x86_64-only product`: PASS;
- `Validate Android runner launcher`: PASS, including stopped-service recovery and persistent service safety;
- Android layout, accessibility boot, APK cache, kernel cache, kernel module and VM hardware contracts: PASS.

Current gate:

- workflow run `34783477192`, attempt 7;
- job `103902284315` targets labels `self-hosted`, `Linux`, `X64`, `android-build`;
- the job remains queued until the WSL runner reconnects;
- when assigned, checkout uses the branch name and `clean: false`, so it will fetch the current branch head while preserving the persistent build workspace.

Promotion rule:

Keep PR #1 in draft and do not merge until the real self-hosted gate proves Android images, preinstalled disk, BIOS boot, UEFI boot, accessibility runtime, VM hardware, QCOW2 integrity and final evidence upload.
