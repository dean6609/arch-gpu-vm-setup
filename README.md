# 🎮 arch-gpu-vm-setup

> Automated GPU passthrough setup for Windows VM gaming on Arch Linux.  
> Supports EasyAntiCheat (Fortnite ✅), Looking Glass, VFIO, patched QEMU/EDK2,  
> and dynamic GPU switching between host and VM without rebooting.

---

## ⚠️ DISCLAIMER — READ BEFORE USING

| | |
|---|---|
| 🔒 | **Educational purposes only.** This project is for learning about Linux virtualization and GPU passthrough. |
| ⚠️ | **Author is not responsible** for any damage, data loss, or account bans that may result from using this software. |
| 📸 | **This is a working snapshot** for the author's specific hardware configuration. It is tested and functional on the author's system only. |
| 🚫 | **No new versions will be released.** This version is final and functional for the creator. |
| 🍴 | **Users can fork and adapt** with AI assistance for their specific system hardware and requirements. |
| ⚖️ | **GPU passthrough and anti-cheat evasion may violate game Terms of Service** and result in account bans. Use at your own risk. |
| ⚠️ | **Tested with linux-zen 6.19.8** — future kernel versions may break VFIO, Looking Glass, or GPU binding. |
| 🔧 | **No maintenance or updates planned.** If something breaks with newer versions, use AI assistance to adapt, specifying these exact versions as your working baseline. |

---

![License](https://img.shields.io/badge/license-GPL--3.0-blue)
![Platform](https://img.shields.io/badge/platform-Arch%20Linux%2B%20Dusky-brightgreen)
![WM](https://img.shields.io/badge/WM-Hyprland%20%2B%20UWSM-purple)
![Status](https://img.shields.io/badge/status-completed-success)
![DE](https://img.shields.io/badge/DE-Dusky%20rice-blue)

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

- **Arch Linux** (not tested on other distros)
- **linux-zen kernel** (REQUIRED — see below)
- Hyprland 0.54.x+
- UWSM 0.26.x+
- yay or paru (AUR helper)
- sudo access

### ⚠️ linux-zen Kernel is REQUIRED

The **linux-zen** kernel is **not optional** and must be installed and set as the default boot option:

**Why linux-zen is required:**
- The ACS override patch (`pcie_acs_override=downstream,multifunction`) is built into linux-zen
- This patch is essential for proper IOMMU group isolation, allowing GPU passthrough to work
- The standard Linux kernel may work but is **NOT tested** — use at your own risk

**Installation and setup:**
```bash
# Install linux-zen and headers
sudo pacman -S linux-zen linux-zen-headers

# Set as default boot entry (replace with your actual entry filename)
sudo bootctl set-default 2026-03-13_13-42-53_linux-zen.conf

# To find your entry filename:
ls /boot/loader/entries/
```

### Note about Dusky rice

This project was developed on the [Dusky rice](https://github.com/dusklinux/dusky) which includes a full Hyprland environment pre-configured. If you use Dusky, everything works out of the box. If not, you need at minimum Hyprland + UWSM plus the standard packages installed by the setup modules.

---

## 📦 Verified Working Versions

These are the exact versions used when this project was built and tested.
If something breaks in the future, try matching these versions.
Using newer versions may or may not work — this project is not actively maintained.

| Component | Version | Notes |
|-----------|---------|-------|
| Arch Linux | Rolling (March 2026) | |
| linux-zen | 6.19.8.zen1-1 | Required — has ACS patch |
| Hyprland | 0.54.2 | |
| UWSM | 0.26.4 | |
| QEMU (compiled) | 10.2.0 | Compiled from source with patches |
| QEMU (system) | 10.2.1-1 | Used as build dependency |
| EDK2/OVMF | 202508-1 | System package for dependencies |
| libvirt | 12.1.0-1 | |
| virt-manager | 5.1.0-3 | |
| swtpm | 0.10.1-1 | |
| Looking Glass | B6 | Compiled from source |
| Mesa | 26.0.2-1 | AMD GPU drivers |
| vulkan-radeon | 26.0.2-1 | |
| yay | 12.5.7 | AUR helper |
| Python | 3.14.3 | |

To install a specific package version in Arch:
```bash
# Downgrade a package if needed
sudo downgrade package-name
# Or from Arch archive:
# https://archive.archlinux.org/packages/
```

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

## 🖱️ Monitor Switching vs Looking Glass

This project supports **two methods** for using the Windows VM with your GPU:

### Method 1: Physical Monitor Input Switching (Default)

This project **intentionally uses physical monitor input switching** instead of Looking Glass window for the primary gaming experience:

| Benefit | Explanation |
|---------|-------------|
| **Native refresh rates** | Use full 240Hz, 144Hz, 120Hz — not limited by Looking Glass frame rate |
| **Lower latency** | Direct display output, no capture/streaming overhead |
| **Better compatibility** | Some games run better with direct GPU output |

**How to use:**
1. Start gaming mode: `./gaming-mode.sh`
2. Switch your monitor's input to the dGPU output (DP or HDMI port on your graphics card)
3. Play your games at native refresh rates
4. When done, switch monitor input back to iGPU output (HDMI/DP on motherboard)
5. Stop gaming mode to return GPU to Linux

### Method 2: Looking Glass Window

Looking Glass is also fully supported for those who prefer a windowed experience:

**How to use:**
1. Start gaming mode: `./gaming-mode.sh`
2. Use the Looking Glass window on your Linux desktop
3. **Capture/Release**: Press `Right Ctrl` (default escape key) to capture or release mouse/keyboard inside the Looking Glass window

**Summary:** Both methods work. Physical switching gives better performance and native refresh rates. Looking Glass window is more convenient for streaming/multitasking.

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

- **[Dusky rice](https://github.com/dusklinux/dusky) + Hyprland + UWSM required** for gaming mode GPU switching
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

### 🏗️ Built with AI Vibecoding

This project was built entirely with AI assistance (vibecoding). The author used AI to:
- Generate and adapt QEMU/EDK2 anti-detection patches
- Create the modular shell script architecture
- Automate GPU binding and switching logic
- Write documentation and troubleshooting guides

**Base projects for adaptation:**
- [AutoVirt](https://github.com/Scrut1ny/AutoVirt) by Scrut1ny — QEMU/EDK2 patches, VM spoofing techniques, project architecture inspiration
- [AutoVirt Demo Video](https://www.youtube.com/watch?v=dakWYBC6Jug) — Shows what's possible with similar setup
- [Omarchy PR #3454](https://github.com/basecamp/omarchy/pull/3454) by slawomir-andreasik — GPU passthrough automation inspiration

### 🛠️ Technologies

- [Looking Glass](https://looking-glass.io/) — Low-latency VM display capture
- [Dusky rice](https://github.com/dusklinux/dusky) — The Hyprland environment this project was built on
- [VFIO community](https://vfio.blogspot.com/) — GPU passthrough documentation

---

## 📄 License

GPL-3.0 — see [LICENSE](LICENSE) file.