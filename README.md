# 🎮 arch-gpu-vm-setup

> Automated GPU passthrough setup for Windows VM gaming on Arch Linux.  
> Supports EasyAntiCheat (Fortnite ✅), VFIO, patched QEMU/EDK2,  
> and dynamic GPU switching between host and VM without rebooting.

---

## ⚠️ DISCLAIMER — READ BEFORE USING

| | |
|---|---|
| 🔒 | **Educational purposes only.** This project is for learning about Linux virtualization and GPU passthrough. |
| ⚠️ | **Author is not responsible** for any damage, data loss, or account bans. |
| 🍴 | **Users can fork and adapt** with AI assistance for their specific system. |
| ⚖️ | **Use at your own risk.** Anti-cheat evasion may violate game Terms of Service. |

---

# Arch Linux GPU Passthrough Gaming Setup (v2.1)

| Status | Details |
| :--- | :--- |
| 🚀 | **Version 2.1 Released.** Major stability fixes, VM anti-detection hardening, and new modules. |
| 🎮 | **Dual-ALT Input Toggle Fixed:** Keyboard + mouse toggle together via `grab_all=on`. |
| 🛡️ | **VM Anti-Detection Hardened:** SMBIOS spoofing, Hyper-V enlightenments, EAC-compatible config. |
| 🌐 | **New Module:** VirtIO Network Driver for full 1Gbps VM networking. |
| ⚠️ | **Tested with linux-zen 6.19.8** — current working baseline. |
| ✅ | **Maintenance Mode:** This project is now considered stable and complete. |

---

![License](https://img.shields.io/badge/license-GPL--3.0-blue)
![Platform](https://img.shields.io/badge/platform-Arch%20Linux%2B%20Dusky-brightgreen)
![WM](https://img.shields.io/badge/WM-Hyprland%20%2B%20UWSM-purple)
![Status](https://img.shields.io/badge/status-completed-success)
![DE](https://img.shields.io/badge/DE-Dusky%20rice-blue)

---

## 🖥️ Terminal Interface

> The setup runs entirely in the terminal via interactive, user-friendly menus.

### v2.1 Changelog

| Component | Change |
|-----------|--------|
| `gaming-mode-daemon.sh` | Fixed Hyprland restart: `uwsm stop` instead of `pkill` (UWSM service has `Restart=no`). |
| `gaming-mode-daemon.sh` | Added `restart_hyprland()` helper used in start/stop/revert flows. |
| `gaming-mode-daemon.sh` | iGPU explicitly bound to `amdgpu` via helper script (was left driverless after vfio-pci unbind). |
| `gaming-mode-helper.sh` | Added `unbind_device`, `clear_override` commands for NOPASSWD sysfs writes. |
| `gaming-mode-setup.sh` | Evdev injection via temp file (fixes bash escaping in heredoc). `-object input-linux` with `grab_all=on`. |
| `gaming-mode-setup.sh` | Audio driver detection ignores `vfio-pci` (defaults to `snd_hda_intel`). |
| `gaming-mode-setup.sh` | Systemd service: `ExecStartPre=mkdir`, stdout to `journal` (fixes duplicate logs). |
| `modules/04_gpu_bind.sh` | Added `modprobe vfio-pci` before bind (fixes hang). GPU selection menu. |
| `modules/08_deploy_vm.sh` | SMBIOS spoofing (MSI B550 TOMAHAWK) + Hyper-V enlightenments for anti-detection. |
| `modules/07_virtio_network.sh` | **New module:** VirtIO driver setup for 1Gbps VM networking. |
| `main.sh` | Added option 9: VirtIO Network Driver. Menu now [0-13, G]. |
| `config.conf` | Fixed GPU mapping (dGPU/iGPU was swapped). |

---

**Main menu preview (v2.1):**
```
╔══════════════════════════════════════════════╗
║         >> GPU Passthrough Gaming <<         ║
║              Arch Linux Edition              ║
╚══════════════════════════════════════════════╝

  [1]  Prerequisites Check
  [2]  BIOS Configuration Guide
  [3]  Virtualization Setup (QEMU/KVM/libvirt)
  [4]  VFIO / GPU Passthrough Configuration
  [5]  GPU Binding Management
  [6]  Compile QEMU (with anti-detection patches)
  [7]  Compile EDK2/OVMF (patched firmware)
  [8]  Deploy Windows VM
  [9]  VirtIO Network Driver (improve VM network speed)
  [10] Fortnite/EAC Specific Patches
  [11] System Diagnostics
  [12] Uninstall Setup
  [G]  Gaming Mode
  [0]  Exit
```

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
[8]  Deploy Windows VM
[9]  Fortnite/EAC Specific Patches
[10] System Diagnostics
[11] Uninstall Setup
[G]  Gaming Mode
```

---

## 🎮 Gaming Mode

The gaming mode script handles automatic GPU switching between Linux and Windows VM:

```bash
# Launch gaming mode (Super+G also works)
./gaming-mode.sh
```

### Gaming Mode Flow
1. **Start**: GPU switches to VM, Hyprland moves to iGPU at 60Hz
2. **Play**: Switch monitor input to DP/HDMI connected to your dGPU
3. **Stop**: GPU returns to Linux, Hyprland switches back to dGPU at full Hz

---

## 🖱️ Monitor Switching & Input Control (Evdev)

This project uses **physical monitor input switching** combined with **Evdev passthrough** for a native gaming experience:

| Feature | Details |
|---------|-------------|
| **Native Refresh Rates** | Use full 240Hz, 144Hz, 120Hz — no streaming overhead. |
| **Zero-Latency Audio** | Native TCP bridge to host PipeWire/PulseAudio. |
| **Seamless Input** | Use `Left Alt + Right Alt` to instantly toggle mouse/keyboard between Linux and Windows. |

**How to use:**
1. Start gaming mode: `./gaming-mode.sh` (or `Super+G`)
2. Switch your monitor's input to the dGPU output.
3. Your keyboard and mouse are automatically captured.
4. **Capture/Release**: Press **both ALT keys** simultaneously to return your mouse to Linux.
5. When done, stop gaming mode to return the GPU to Linux.

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
| SMBIOS/DMI anomalies | Spoofed MSI B550 TOMAHAWK + AMI BIOS via sysinfo |
| Hyper-V enlightenments | Enabled (relaxed, vapic, spinlocks, vpindex, synic, stimer) |
| KVM clock source | disabled |
| MSR filtering | fault mode |
| Disk model names | spoofed to real manufacturers |
| MAC address | host OUI used |
| Evdev input | `-object input-linux` with `grab_all=on` for simultaneous KB+Mouse toggle |

### AMD Driver Compatibility

- **AMD driver 25.9.1** is the last known working version for EAC games
- Newer AMD drivers (25.10.2+) trigger `aticfx64.dll` / `atidxx64.dll` untrusted in EAC
- SMBIOS spoofing prevents AMD Adrenalin from detecting the VM environment

---

## 📁 Project Structure

```
arch-gpu-vm-setup/
├── main.sh                    # Main interactive menu
├── utils.sh                   # Shared helpers and logging
├── gaming-mode.sh             # Gaming mode interactive menu
├── gaming-mode-daemon.sh      # Background daemon for GPU switching
├── gaming-mode-helper.sh      # Privileged helper (NOPASSWD sudoers)
├── gaming-mode-setup.sh       # First-time gaming mode configuration wizard
├── gaming-mode.conf           # Generated config (auto-created)
├── config.conf                # GPU/IOMMU config (auto-created)
├── modules/
│   ├── 00_prereq_check.sh     # Hardware/software verification
│   ├── 01_bios_guide.sh       # BIOS configuration guide
│   ├── 02_virtualization.sh   # QEMU/KVM/libvirt installation
│   ├── 03_vfio_setup.sh       # VFIO/IOMMU configuration
│   ├── 04_gpu_bind.sh         # Dynamic GPU binding (GPU selection menu)
│   ├── 05_qemu_patched.sh     # Compile patched QEMU
│   ├── 06_edk2_patched.sh     # Compile patched EDK2/OVMF
│   ├── 07_virtio_network.sh   # VirtIO network driver setup
│   ├── 08_deploy_vm.sh        # Windows VM deployment (with SMBIOS spoofing)
│   ├── 09_fortnite_patches.sh # EAC anti-detection checklist
│   ├── 10_diagnostics.sh      # System diagnostics
│   └── 11_uninstall.sh        # Complete removal
├── firmware/
│   ├── OVMF_CODE.fd           # Patched UEFI firmware code
│   ├── OVMF_VARS.fd           # UEFI variables template
│   └── virtio-win.iso         # VirtIO drivers for Windows
└── patches/
    ├── QEMU/                  # QEMU anti-detection patches
    └── EDK2/                  # EDK2/OVMF firmware patches
```

---

## ⚠️ Important Notes

- **Hyprland + UWSM required** for gaming mode GPU switching. This project was developed on the [Dusky rice](https://github.com/dusklinux/dusky) but Dusky is NOT required.
- **AMD GPUs** require VBIOS dump to fix Error Code 43 in Windows
```bash
  sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:01:00.0/rom && \
  cat /sys/bus/pci/devices/0000:01:00.0/rom > firmware/rx580.rom && \
  echo 0 > /sys/bus/pci/devices/0000:01:00.0/rom'
```
  > ⚠️ Replace `0000:01:00.0` with YOUR GPU's actual PCI address.
  > Find it with: `lspci | grep -i vga`
- **VALORANT** does not work — Vanguard uses kernel-level detection
- Backup your system before running VFIO configuration

---

## 🔧 Adapting for Your System

This project is a working snapshot for specific hardware. To adapt it for your system:

1. **Fork this repository**
2. **Use AI assistance** (Claude, ChatGPT, etc.) with this prompt as a starting point:
   > I want to adapt arch-gpu-vm-setup (https://github.com/dean6609/arch-gpu-vm-setup) for my system. My hardware is: [describe your CPU, GPUs, motherboard]. The verified working versions are listed in the README. What do I need to change for my specific setup?
3. **Key files to adapt:**
   - `gaming-mode-setup.sh` — setup wizard (triggered automatically on first run)
   - `modules/03_vfio_setup.sh` — GPU PCI addresses are auto-detected
   - `modules/08_deploy_vm.sh` — CPU topology is auto-detected via lscpu
4. **Common issues and where to look:**
   - AMD GPU Error Code 43 → VBIOS dump required (see Important Notes)
   - IOMMU groups mixed → use linux-zen with pcie_acs_override kernel parameter
   - Black screen after GPU switch → check UWSM env-hyprland WLR_DRM_DEVICES value

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

- [Dusky rice](https://github.com/dusklinux/dusky) — The Hyprland environment this project was built on
- [VFIO community](https://vfio.blogspot.com/) — GPU passthrough documentation

---

## 📄 License

GPL-3.0 — see [LICENSE](LICENSE) file.