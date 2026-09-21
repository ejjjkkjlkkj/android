# AccessibleAndroid 17 — VMware-first rebuild

This branch rebuilds the x86_64 target around VMware Workstation as a first-class
runtime instead of treating VMware as a late compatibility check.

## Hardware contract

| Function | Primary VMware device | Required Linux path | Fallback |
| --- | --- | --- | --- |
| Boot storage | VMware PVSCSI | `CONFIG_SCSI_VMW_PVSCSI=y` | AHCI / NVMe |
| Graphics | VMware SVGA | `CONFIG_DRM_VMWGFX=y` | basic DRM/framebuffer |
| Network | VMXNET3 | `CONFIG_VMXNET3=y` | E1000 / E1000E |
| Audio | Intel HDA emulation | `CONFIG_SND_HDA_INTEL=y` | ES1371 |
| Keyboard/mouse | PS/2 + USB HID | i8042, atkbd, psmouse, HID | USB HID |
| USB | xHCI | `CONFIG_USB_XHCI_HCD=y` | EHCI/OHCI/UHCI |
| Host/guest | VMCI + VSOCK | VMCI + VMware VSOCK | ADB/network |

Boot-critical storage and input drivers are built into the kernel, not deferred
to Android vendor module loading.

## Build pipeline

1. Synchronize AOSP Android 17 / API 37.
2. Synchronize Android Common Kernel 6.18.
3. Apply `kernel/vmware_x86_64.fragment` to the upstream server x86_64 profile.
4. Build the kernel and stage it into the AccessibleAndroid device tree.
5. Build the accessibility packages and Android images.
6. Produce the preinstalled GPT image.
7. Convert the raw disk to VMDK and emit a VMware `.vmx` configuration.
8. Boot under VMware and run `scripts/verify-vmware-runtime-adb.sh`.
9. A release is blocked unless graphics, audio, input, networking, storage,
   screen reader and offline TTS all pass.

## Graphics note

`vmwgfx` only provides the Linux DRM/KMS kernel side. Android still requires a
working DRM/gralloc/HWC userspace path. The VMware runtime gate therefore checks
for `/dev/dri/card0`; graphical Android validation remains separate from merely
having the kernel driver.

## Accessibility gate

A VMware build is not releasable just because Android reaches the launcher.
Speech must be available, an accessibility service must be enabled, keyboard
navigation must work, audio must be real (not discarded), and the recovery path
must remain usable without sight.

## Non-goals

VMware Tools / open-vm-tools integration is not a replacement for kernel device
support. Clipboard, dynamic resize and host integration are a later userspace
layer after the base VM boots and is accessible.
