# UTM design imports for AccessibleQEMU

UTM is used as an engineering reference for AccessibleQEMU. The pinned source is synchronized by `scripts/sync-utm-upstreams.sh` into `.work/utm-reference`; it is not copied over the Android platform tree and it is not the Windows frontend.

## Pinned reference

- UTM repository: `utmapp/UTM`
- UTM revision: `b6f7475be54f9cb542c46b131319454b83489ced` (5.0.5 beta source)
- UTM license: Apache-2.0 for the UTM frontend; UTM documents additional (L)GPL/native dependencies.
- UTM QEMU repository: `utmapp/qemu`
- QEMU release referenced by the pinned UTM source: `v10.0.12-utm`, commit `6601422e1fff2da1376faafb1e4c2c5cdb2d8003`.
- Newer UTM QEMU engineering head inspected: `b44153a4b6aabf86edebf92199b14aec26e15d59` on `utm-edition`.

## Architecture ideas we adopt

UTM separates its frontend, persistent VM configuration, QEMU argument generation, the QEMU process, and runtime QMP management. AccessibleQEMU will use the same separation in a Windows-first Rust implementation:

1. **Serializable VM configuration** — VM settings are data, not UI state. Configurations can be saved, loaded, validated and migrated.
2. **QEMU command builder** — one module converts validated configuration into deterministic QEMU arguments. The UI never assembles ad-hoc command strings.
3. **Runtime QMP manager** — lifecycle, media, status, snapshots and later hot-plug operations go through structured QMP JSON rather than simulated keystrokes.
4. **Process isolation** — QEMU remains a child process of AccessibleQEMU on Windows. A crash in the guest/backend must not take down the accessible manager.
5. **Display/backend separation** — the accessible manager must remain fully usable even if the guest display is unavailable. Serial/QMP diagnostics are first-class.
6. **Removable media and VM library** — configurations own media references and can be reopened without rebuilding a command line manually.

## Accessibility improvements beyond UTM

AccessibleQEMU is not a port of UTM's SwiftUI frontend. Its release requirements are stricter for screen-reader use:

- Windows 11 26H2 x64 is the primary host target.
- UI Automation exposure is mandatory for every interactive control through AccessKit/egui.
- NVDA, JAWS and Narrator validation is required on a real Windows 11 26H2 host before release.
- Every critical operation must be keyboard reachable and have a visible/textual name.
- VM state and errors must be presented as text, not only through icons, color, animation or the guest framebuffer.
- QMP and serial logging remain usable when the graphical guest display fails.
- No destructive disk action is triggered merely by focus, selection or startup.

## UTM features that are not imported directly

UTM's Apple-specific layers are intentionally not copied into the Windows build:

- SwiftUI/AppKit/UIKit frontend code.
- Hypervisor.framework and Virtualization.framework integration.
- Apple sandbox/XPC launch plumbing.
- Metal/Cocoa-specific display code.
- APRR/iOS JIT mechanisms.

Where UTM carries QEMU patches, each candidate patch must be reviewed individually against the current QEMU version and its license before adoption. We do not apply the complete UTM patch set to a newer QEMU blindly.

## High-value AccessibleQEMU roadmap derived from the review

- Persistent JSON VM configuration and schema versioning.
- Deterministic Q35 device topology for AccessibleAndroid.
- RAW/QCOW2/VDI/VMDK disk format detection.
- Named serial log file and accessible diagnostics view.
- Structured QMP requests with arguments and events.
- ISO insert/eject and removable-media changes.
- Snapshot create/list/restore/delete with explicit confirmation.
- SPICE display/agent evaluation for clipboard, dynamic resolution and richer guest integration, without making SPICE a prerequisite for screen-reader control of the manager.
- USB redirection only after a permission and accessibility design review.
- VM templates/wizard, starting with AccessibleAndroid 17.

The goal is to combine UTM's mature QEMU-management architecture with a Windows-native accessibility contract rather than to reproduce its Apple-only UI.
