# 🎮 arch-gpu-vm-setup

> Automated GPU passthrough setup for Windows VM gaming on Arch Linux.  
> Supports EasyAntiCheat (Fortnite ✅), Looking Glass, VFIO, patched QEMU/EDK2,  
> and dynamic GPU switching between host and VM without rebooting.

![License](https://img.shields.io/badge/license-GPL--3.0-blue)
![Platform](https://img.shields.io/badge/platform-Arch%20Linux-brightgreen)
![WM](https://img.shields.io/badge/WM-Hyprland%20%2B%20UWSM-purple)
![Status](https://img.shields.io/badge/status-working-success)

---

## ✅ Tested & Working

| Game | Anti-Cheat | Status |
|------|-----------|--------|
| Fortnite | EasyAntiCheat | ✅ Works |
| Counter-Strike 2 | VAC | ✅ Works |
| The Finals | EasyAntiCheat | ✅ Works |
| Deadlock | VAC | ✅ Works |
| VALORANT | Vanguard | ❌ Not working |

---

## 🖥️ Hardware Requirements

- **2 GPUs**: 1 dedicated (for VM passthrough) + 1 integrated (for host)
- **CPU**: AMD with SVM or Intel with VT-x/VT-d
- **RAM**: 16GB minimum (8GB host + 8GB VM)
- **BIOS**: IOMMU enabled, Primary Display = iGPU

### Tested Hardware
- NVIDIA RTX 5070 + AMD Ryzen 7 8700G (iGPU)
- NVIDIA RTX 4090 + Intel i9-13900K (iGPU)
- NVIDIA RTX 3060 Mobile + Intel i7-11800H (Lenovo Legion 5)
- NVIDIA RTX 2060 + AMD Sapphire 4GB (iGPU)
- **AMD RX 580 + AMD Ryzen 5 5600G (iGPU) ← This repo's primary test system**

---

## 📋 Requirements

- Arch Linux (kernel-zen recommended for ACS patch support)
- Hyprland + UWSM (required for gaming-mode GPU switching)
- yay or paru (AUR helper)
- sudo access

---

## 🚀 Quick Start

### 1. Clone the repository
```bash
git clone https://github.com/dean6609/arch-gpu-vm-setup
cd arch-gpu-vm-setup
```

### 2. Run the main setup menu
```bash
./main.sh
```

### 3. Follow the menu in order
```
[1]  Prerequisites Check
[2]  BIOS Configuration Guide
[3]  Virtualization Setup (QEMU/KVM/libvirt)
[4]  VFIO / GPU Passthrough Configuration
[5]  GPU Binding Management
[6]  Compile QEMU (with anti-detection patches)
[7]  Compile EDK2/OVMF (patched firmware)
[8]  Install Looking Glass
[9]  Deploy Windows VM
[10] Fortnite/EAC Specific Patches
[11] System Diagnostics
[G]  Gaming Mode
```

---

## 🎮 Gaming Mode

The gaming mode script handles automatic GPU switching between Linux and Windows VM:

```bash
# First time setup (run once)
./gaming-mode-setup.sh

# Launch gaming mode
./gaming-mode.sh
# Or press Super+G (configured automatically by setup wizard)
```

### Gaming Mode Flow
1. **Start**: GPU switches to VM, Hyprland moves to iGPU at 60Hz
2. **Play**: Switch monitor input to DP/HDMI connected to your dGPU
3. **Stop**: GPU returns to Linux, Hyprland switches back to dGPU at full Hz

---

## 🛡️ Anti-Detection Patches

This project compiles patched versions of QEMU and EDK2/OVMF that hide 
the hypervisor from anti-cheat systems:

| Detection Vector | Fix Applied |
|-----------------|-------------|
| KVM signature in CPUID | kvm.hidden=on + QEMU patch |
| Hypervisor bit | disabled in CPU features |
| VMware backdoor (VMPort) | disabled |
| PMU | disabled |
| SMBIOS/DMI anomalies | host SMBIOS dump |
| KVM clock source | disabled |
| MSR filtering | fault mode |
| Disk model names | spoofed to real manufacturers |
| MAC address | host OUI used |

---

## 📁 Project Structure

```
arch-gpu-vm-setup/
├── main.sh                    # Main interactive menu
├── utils.sh                   # Shared helpers and logging
├── gaming-mode.sh             # Gaming mode interactive menu
├── gaming-mode-daemon.sh      # Background daemon for GPU switching
├── gaming-mode-setup.sh       # First-time gaming mode configuration wizard
├── modules/
│   ├── 00_prereq_check.sh     # Hardware/software verification
│   ├── 01_bios_guide.sh       # BIOS configuration guide
│   ├── 02_virtualization.sh   # QEMU/KVM/libvirt installation
│   ├── 03_vfio_setup.sh       # VFIO/IOMMU configuration
│   ├── 04_gpu_bind.sh         # Dynamic GPU binding
│   ├── 05_qemu_patched.sh     # Compile patched QEMU
│   ├── 06_edk2_patched.sh     # Compile patched EDK2/OVMF
│   ├── 07_looking_glass.sh    # Looking Glass installation
│   ├── 08_deploy_vm.sh        # Windows VM deployment
│   ├── 09_fortnite_patches.sh # EAC anti-detection checklist
│   ├── 10_diagnostics.sh      # System diagnostics
│   └── 11_uninstall.sh        # Complete removal
└── patches/
    ├── QEMU/                  # QEMU anti-detection patches
    └── EDK2/                  # EDK2/OVMF firmware patches
```

---

## ⚠️ Important Notes

- **Hyprland + UWSM required** for gaming mode GPU switching
- **AMD GPUs** require VBIOS dump to fix Error Code 43 in Windows
```bash
  sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:01:00.0/rom && \
  cat /sys/bus/pci/devices/0000:01:00.0/rom > firmware/rx580.rom && \
  echo 0 > /sys/bus/pci/devices/0000:01:00.0/rom'
```
- **VALORANT** does not work — Vanguard uses kernel-level detection
- Backup your system before running VFIO configuration

---

## 🤝 Credits & References

- [AutoVirt](https://github.com/Scrut1ny/AutoVirt) — QEMU/EDK2 patches and VM spoofing techniques
- [Omarchy PR #3454](https://github.com/basecamp/omarchy/pull/3454) — GPU passthrough automation inspiration
- [Looking Glass](https://looking-glass.io/) — Low-latency VM display
- [VFIO community](https://vfio.blogspot.com/) — GPU passthrough documentation

---

## 📄 License

GPL-3.0 — see [LICENSE](LICENSE) file.