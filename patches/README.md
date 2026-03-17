# Patches Directory

This directory should contain the following patches:

## QEMU Patches

- `QEMU/AMD-v10.2.0.patch` - Disables KVM paravirtualization features for AMD CPUs
- `QEMU/Intel-v10.2.0.patch` - Disables KVM paravirtualization features for Intel CPUs
- `QEMU/kvm-clock-disable.patch` - Alternative patch to disable kvmclock
- `QEMU/hypervisor-bit-clear.patch` - Clears hypervisor bit in CPUID

## EDK2 Patches

- `EDK2/AMD-edk2-stable202602.patch` - Patches OVMF for AMD systems
- `EDK2/Intel-edk2-stable202602.patch` - Patches OVMF for Intel systems
- `EDK2/ovmf-spoof.patch` - Generic OVMF spoofing patches

## Kernel Patches (for VM guest)

- `Kernel/amd-linux-6.0.0-rc6.patch` - Kernel patches for AMD inside guest
- `Kernel/intel-linux-6.0.0-rc6.patch` - Kernel patches for Intel inside guest

## Guest ACPI Tables

- `Guest/fake_battery.dsl` - Fake battery ACPI table for laptops
- `Guest/spoofed_devices.dsl` - Spoofed ACPI devices

---

## Creating Patches

### QEMU Patch Example

```bash
cd /path/to/qemu
# Make your modifications to source code
git diff HEAD > /path/to/patches/QEMU/AMD-v10.2.0.patch
```

### EDK2 Patch Example

```bash
cd /path/to/edk2
# Make your modifications to source code  
git diff HEAD > /path/to/patches/EDK2/AMD-edk2-stable202602.patch
```
