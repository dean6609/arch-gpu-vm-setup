# arch-gpu-vm-setup

> Automated GPU passthrough for Windows VM gaming on Arch Linux. Zero-reboot GPU switching, anti-detection patches, and a polished CLI — all in one.

[![License](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Arch%20Linux-brightgreen)](https://archlinux.org)
[![WM](https://img.shields.io/badge/WM-Hyprland%20%2B%20UWSM-purple)](https://hyprland.org)
[![Status](https://img.shields.io/badge/status-v3.0--rc-success)](https://github.com/dean6609/arch-gpu-vm-setup)

---

## Quick Install

```bash
git clone https://github.com/dean6609/arch-gpu-vm-setup && cd arch-gpu-vm-setup && npm install && npm run dev
```

---

## Quick Start

```bash
git clone https://github.com/dean6609/arch-gpu-vm-setup
cd arch-gpu-vm-setup
npm install
npm run dev
```

Navigate the menu with arrow keys or mouse. Press <kbd>Enter</kbd> to select.

---

## Requirements

| Requirement | Details |
|---|---|
| **OS** | Arch Linux |
| **Kernel** | `linux-zen` — required for ACS override patch |
| **Compositor** | Hyprland 0.54.x+ |
| **Session Manager** | UWSM 0.26.x+ |
| **GPUs** | 2 GPUs — one dedicated (for VM) + one integrated (for host) |
| **CPU** | AMD with SVM or Intel with VT-x/VT-d |
| **RAM** | 16 GB minimum (8 GB host + 8 GB VM) |
| **BIOS** | IOMMU enabled, Primary Display set to iGPU |

> [!IMPORTANT]
> **Why `linux-zen`?** The `pcie_acs_override` patch is built into `linux-zen`. It is essential for proper IOMMU group isolation. The standard kernel may work but is untested.
>
> > ```bash
> > sudo pacman -S linux-zen linux-zen-headers
> > sudo bootctl set-default <your-linux-zen-entry>
> > ```

---

## Gaming Mode

> [!NOTE]
> Switch your GPU between Linux and a Windows VM **without rebooting**.

```bash
npm run dev  # Select [G] Gaming Mode
```

**How it works:**

| Step | Action | Result |
|---|---|---|
| **Start** | GPU transfers to VM | Hyprland moves to iGPU at 60 Hz |
| **Play** | Switch monitor input to dGPU output | Full performance on Windows VM |
| **Stop** | GPU returns to Linux | Hyprland switches back to native refresh rate |

Toggle keyboard and mouse between host and VM with <kbd>Left Alt</kbd> + <kbd>Right Alt</kbd>.

> [!TIP]
> Hyprland + UWSM is required for gaming mode GPU switching. This project was developed on [Dusky Linux](https://github.com/dusklinux/dusky), but Dusky is not required.

---

## Verified Versions

| Component | Version | Notes |
|---|---|---|
| **AMD GPU Driver** | 25.9.1 | Last known working version for EAC games |
| **Hyprland** | 0.54.x+ | Required for GPU switching |
| **UWSM** | 0.26.x+ | Required for session management |
| **Kernel** | linux-zen | ACS override patch included |

> [!WARNING]
> **AMD driver note:** Versions 25.10.2+ trigger `aticfx64.dll` untrusted in EasyAntiCheat. Pin to 25.9.1 for EAC compatibility.

---

## Modules

| # | Module | Description |
|---|---|---|
| 01 | Prerequisites Check | Verifies CPU, GPU, IOMMU, RAM, and bootloader |
| 02 | BIOS Configuration Guide | Guides you through BIOS settings for your CPU |
| 03 | Virtualization Setup | Installs QEMU, KVM, libvirt |
| 04 | VFIO / GPU Passthrough | Configures IOMMU groups, kernel params, and VFIO |
| 05 | GPU Binding Management | Dynamically bind/unbind GPU between host and VM |
| 06 | Compile QEMU | Builds QEMU with anti-detection patches |
| 07 | Compile EDK2/OVMF | Compiles patched firmware |
| 08 | Deploy Windows VM | Creates the VM with SMBIOS spoofing |
| 09 | VirtIO Network Driver | Enables 1 Gbps VM networking |
| 10 | Fortnite / EAC Patches | Anti-cheat evasion checklist |
| 11 | System Diagnostics | Full system status report |
| 12 | Uninstall Everything | Clean removal |
| **G** | Gaming Mode | One-click GPU switch — no reboot needed |

---

## Tested Hardware

| dGPU | iGPU | Status |
|---|---|---|
| NVIDIA RTX 5070 | AMD Ryzen 7 8700G | <span style="color:#2ea44f">Verified</span> |
| NVIDIA RTX 4090 | Intel i9-13900K | <span style="color:#2ea44f">Verified</span> |
| NVIDIA RTX 3060 Mobile | Intel i7-11800H (Lenovo Legion 5) | <span style="color:#2ea44f">Verified</span> |
| NVIDIA RTX 2060 | AMD Sapphire 4GB | <span style="color:#2ea44f">Verified</span> |
| AMD RX 580 | AMD Ryzen 5 5600G | <span style="color:#2ea44f">Verified</span> (primary test system) |

---

## Anti-Cheat Compatibility

| Game | Anti-Cheat | Status |
|---|---|---|
| Fortnite | EasyAntiCheat | <span style="color:#2ea44f">Compatible</span> |
| Counter-Strike 2 | VAC | <span style="color:#2ea44f">Compatible</span> |
| The Finals | EasyAntiCheat | <span style="color:#2ea44f">Compatible</span> |
| Deadlock | VAC | <span style="color:#2ea44f">Compatible</span> |
| VALORANT | Vanguard | <span style="color:#f85149">Not supported</span> |

### Detection Vectors Concealed

| Vector | Mitigation |
|---|---|
| KVM signature in CPUID | `kvm.hidden=on` + QEMU patch |
| Hypervisor bit | Disabled in CPU features |
| VMware backdoor | Disabled |
| PMU | Disabled |
| SMBIOS/DMI | Spoofed to MSI B550 TOMAHAWK + AMI BIOS |
| Hyper-V enlightenments | Enabled (relaxed, vapic, spinlocks, vpindex, synic, stimer) |
| KVM clock source | Disabled |
| MSR filtering | Fault mode |
| Disk model names | Spoofed to real manufacturers |
| MAC address | Host OUI used |
| Evdev input | `-object input-linux` with `grab_all=on` |

---

## Project Structure

```
arch-gpu-vm-setup/
├── src/                          # Ink CLI (TypeScript + React)
│   ├── components/               # UI components (menu, gaming mode, script runner)
│   ├── hooks/                    # Terminal resize tracking
│   ├── utils/                    # Colors, config, system detection, gaming mode
│   └── index.tsx                 # Entry point
├── scripts/                      # Bash backend
│   ├── utils.sh                  # Shared helpers and logging
│   ├── gaming-mode*.sh           # Gaming mode (daemon, helper, setup, menu)
│   ├── modules/                  # Setup modules (00–12)
│   └── patches/                  # QEMU, EDK2, and kernel patches
├── package.json
├── vitest.config.ts
└── tsconfig.json
```

---

## Commands

| Command | Description |
|---|---|
| `npm run dev` | Start interactive CLI (development) |
| `npm start` | Start compiled CLI (production) |
| `npm run build` | Compile TypeScript |
| `npm run type-check` | Type check without building |
| `npm test` | Run unit tests |
| `npm run test:watch` | Run tests in watch mode |

---

## Adapting for Your System

This project is a working snapshot for specific hardware. To adapt it:

1. **Fork this repository**
2. **Key files to review:**
   - `scripts/gaming-mode-setup.sh` — auto-detects monitors, DRM devices, and VMs
   - `scripts/modules/03_vfio_setup.sh` — GPU PCI addresses are auto-detected
   - `scripts/modules/08_deploy_vm.sh` — CPU topology is auto-detected via `lscpu`
3. **Common issues:**
   - **AMD GPU Error 43** — VBIOS dump required (see below)
   - **IOMMU groups mixed** — use `linux-zen` with `pcie_acs_override` kernel parameter
   - **Black screen after GPU switch** — check UWSM `WLR_DRM_DEVICES` value

> [!TIP]
> **Using AI agents to adapt this project:** Fork this repository and use AI coding agents (Claude, Qwen Code, GitHub Copilot, etc.) to adapt it for your specific hardware. Describe your CPU, GPUs, and motherboard to the agent, and it will identify which config files need changes and generate the appropriate patches.

> [!IMPORTANT]
> **AMD GPU Error 43 fix:** A VBIOS dump is required for AMD GPUs. Extract it with:
>
> > ```bash
> > sudo sh -c 'echo 1 > /sys/bus/pci/devices/YOUR_GPU_PCI/rom && \
> > cat /sys/bus/pci/devices/YOUR_GPU_PCI/rom > firmware/rx580.rom && \
> > echo 0 > /sys/bus/pci/devices/YOUR_GPU_PCI/rom'
> > ```
> >
> > Find your GPU PCI address with: `lspci | grep -i vga`

> [!CAUTION]
> **VALORANT is not supported** — Vanguard uses kernel-level detection that cannot be bypassed via VM spoofing.
>
> > **Back up your system** before running VFIO configuration.

---

## License

[GPL-3.0](LICENSE)
