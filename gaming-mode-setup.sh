#!/usr/bin/env bash

# =============================================================================
# Gaming Mode Setup Wizard
# Generates gaming-mode.conf for system-specific configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

# --- SECTION 1: Requirements check ---
fmtr::box_text "Gaming Mode Setup Wizard"
fmtr::info "Requirements: Arch Linux + Hyprland + UWSM"

# Verify Hyprland is running
if ! command -v hyprctl &>/dev/null || ! hyprctl monitors &>/dev/null 2>&1; then
	fmtr::error "Hyprland is not running. This script requires Hyprland."
	fmtr::info "Run this wizard from within a Hyprland session."
	exit 1
fi

# Verify UWSM is installed
if ! command -v uwsm &>/dev/null; then
	fmtr::error "UWSM not found. Install it: yay -S uwsm"
	exit 1
fi

# Verify config.conf exists (from module 03)
if [[ ! -f "${SCRIPT_DIR}/config.conf" ]]; then
	fmtr::error "config.conf not found. Run module 04 (VFIO Setup) first."
	exit 1
fi

# Load GPU info from config.conf
source "${SCRIPT_DIR}/config.conf"
if [[ -z "$GPU_PCI_ADDR" ]]; then
	fmtr::error "GPU_PCI_ADDR not found in config.conf. Run module 04 first."
	exit 1
fi

# --- SECTION 2: Detect GPU PCI addresses ---
# Read from config.conf (already set by module 03):
#   GPU_PCI_ADDR → main GPU PCI address (e.g. 0000:01:00.0)
#   GPU_AUDIO_IDS / GPU_AUDIO_PCI → audio device

fmtr::log "GPU detected from config.conf: $GPU_PCI_ADDR"

# Auto-detect audio sibling (same slot, function 1)
local gpu_slot="${GPU_PCI_ADDR%.*}"
local gpu_audio_pci="${gpu_slot}.1"
if [[ -e "/sys/bus/pci/devices/${gpu_audio_pci}" ]]; then
	fmtr::log "GPU audio device detected: $gpu_audio_pci"
else
	fmtr::warn "No audio device found at $gpu_audio_pci"
	gpu_audio_pci=""
fi

# --- SECTION 3: Detect DRM card numbers ---
# Map PCI IDs to DRM card numbers dynamically
local dgpu_vendor dgpu_device
dgpu_vendor=$(cat "/sys/bus/pci/devices/${GPU_PCI_ADDR}/vendor" 2>/dev/null | tr -d '0x')
dgpu_device=$(cat "/sys/bus/pci/devices/${GPU_PCI_ADDR}/device" 2>/dev/null | tr -d '0x')
local dgpu_pci_id="${dgpu_vendor}:${dgpu_device}"

local drm_dgpu="" drm_igpu=""
for card in /sys/class/drm/card[0-9]*; do
	[[ -d "$card/device" ]] || continue
	local card_vendor card_device
	card_vendor=$(cat "$card/device/vendor" 2>/dev/null | tr -d '0x')
	card_device=$(cat "$card/device/device" 2>/dev/null | tr -d '0x')
	local card_pci_id="${card_vendor}:${card_device}"
	local card_name=$(basename "$card")

	if [[ "$card_pci_id" == "$dgpu_pci_id" ]]; then
		drm_dgpu="/dev/dri/${card_name}"
		fmtr::log "dGPU DRM device: $drm_dgpu"
	else
		drm_igpu="/dev/dri/${card_name}"
		fmtr::log "iGPU DRM device: $drm_igpu"
	fi
done

if [[ -z "$drm_dgpu" || -z "$drm_igpu" ]]; then
	fmtr::error "Could not detect both iGPU and dGPU DRM devices."
	fmtr::info "Make sure both GPUs are active (dGPU in amdgpu, not vfio-pci)"
	exit 1
fi

# --- SECTION 4: Detect monitors ---
# Get all monitors from Hyprland
fmtr::info "Detected monitors:"
hyprctl monitors -j 2>/dev/null | python3 -c "
import json, sys
monitors = json.load(sys.stdin)
for i, m in enumerate(monitors):
    print(f'  [{i+1}] {m[\"name\"]} - {m[\"width\"]}x{m[\"height\"]}@{m[\"refreshRate\"]:.2f}Hz - {m.get(\"description\",\"\")}')
"

# Ask which monitor is connected to iGPU (HDMI from motherboard)
local igpu_monitor
while :; do
	read -rp "$(fmtr::ask_inline 'Enter the name of the iGPU monitor (e.g. HDMI-A-4): ')" igpu_monitor
	if hyprctl monitors | grep -q "Monitor ${igpu_monitor}"; then
		fmtr::log "iGPU monitor confirmed: $igpu_monitor"
		break
	fi
	fmtr::error "Monitor '$igpu_monitor' not found. Try again."
done

# Ask which monitor is connected to dGPU (DisplayPort to RX580/dGPU)
local dgpu_monitor
while :; do
	read -rp "$(fmtr::ask_inline 'Enter the name of the dGPU monitor (e.g. DP-2): ')" dgpu_monitor
	if hyprctl monitors | grep -q "Monitor ${dgpu_monitor}"; then
		fmtr::log "dGPU monitor confirmed: $dgpu_monitor"
		break
	fi
	fmtr::error "Monitor '$dgpu_monitor' not found. Try again."
done

# Ask desired refresh rates
local igpu_hz dgpu_hz
read -rp "$(fmtr::ask_inline 'Refresh rate for iGPU monitor when gaming (default 60): ')" igpu_hz
igpu_hz=${igpu_hz:-60}
read -rp "$(fmtr::ask_inline 'Refresh rate for dGPU monitor in Linux mode (default 240): ')" dgpu_hz
dgpu_hz=${dgpu_hz:-240}

# Ask resolution (default 1920x1080)
local resolution
read -rp "$(fmtr::ask_inline 'Monitor resolution (default 1920x1080): ')" resolution
resolution=${resolution:-1920x1080}

# --- SECTION 5: Detect UWSM env file ---
# UWSM env-hyprland is the file that sets WLR_DRM_DEVICES and AQ_DRM_DEVICES
# Common locations:
local uwsm_env=""
local uwsm_candidates=(
	"$HOME/.config/uwsm/env-hyprland"
	"$HOME/.config/uwsm/env"
)
for candidate in "${uwsm_candidates[@]}"; do
	if [[ -f "$candidate" ]]; then
		if grep -q "WLR_DRM_DEVICES\|AQ_DRM_DEVICES" "$candidate"; then
			uwsm_env="$candidate"
			fmtr::log "Found UWSM env file with DRM vars: $uwsm_env"
			break
		fi
	fi
done

if [[ -z "$uwsm_env" ]]; then
	# No existing DRM vars found — ask user or create
	fmtr::warn "No UWSM env file with WLR_DRM_DEVICES/AQ_DRM_DEVICES found."
	fmtr::info "Candidates checked: ${uwsm_candidates[*]}"

	local create_env
	read -rp "$(fmtr::ask_inline "Create env-hyprland with DRM vars at ${uwsm_candidates[0]}? [y/n]: ")" create_env
	if [[ "${create_env,,}" == "y"* ]]; then
		mkdir -p "$(dirname "${uwsm_candidates[0]}")"
		cat >>"${uwsm_candidates[0]}" <<EOF

# GPU DRM device selection (managed by gaming-mode)
export WLR_DRM_DEVICES=${drm_dgpu}
export AQ_DRM_DEVICES=${drm_dgpu}
EOF
		uwsm_env="${uwsm_candidates[0]}"
		fmtr::log "Created UWSM env entries in $uwsm_env"
	else
		fmtr::error "UWSM env file required. Aborting."
		exit 1
	fi
fi

# --- SECTION 6: Detect Hyprland monitors.conf ---
# Find the monitors.conf that Hyprland actually reads
# Check multiple possible locations in order of priority:
local monitors_conf=""
local monitors_candidates=(
	"$HOME/.config/hypr/edit_here/source/monitors.conf"
	"$HOME/.config/hypr/monitors.conf"
	"$HOME/.config/hypr/source/monitors.conf"
	"$HOME/.config/hypr/config/monitors.conf"
)

for candidate in "${monitors_candidates[@]}"; do
	if [[ -f "$candidate" ]]; then
		monitors_conf="$candidate"
		fmtr::log "Found monitors.conf: $monitors_conf"
		break
	fi
done

if [[ -z "$monitors_conf" ]]; then
	fmtr::warn "Could not auto-detect monitors.conf location."
	read -rp "$(fmtr::ask_inline 'Enter full path to your Hyprland monitors.conf: ')" monitors_conf
	if [[ ! -f "$monitors_conf" ]]; then
		fmtr::error "File not found: $monitors_conf"
		exit 1
	fi
fi

# --- SECTION 7: Detect VM name ---
local vm_name="WindowsVM"
fmtr::info "Checking for existing VMs..."
local available_vms
available_vms=$(virsh list --all --name 2>/dev/null | grep -v "^$")

if [[ -n "$available_vms" ]]; then
	fmtr::info "Available VMs:"
	echo "$available_vms" | nl -w2 -s') '
	read -rp "$(fmtr::ask_inline 'Enter VM name (default: WindowsVM): ')" vm_input
	vm_name=${vm_input:-WindowsVM}
fi
fmtr::log "VM name: $vm_name"

# --- SECTION 8: Detect Hyprland keyboard shortcut ---
# Check if Super+G is already bound in the user's Hyprland config
local keybind_file=""
local keybind_candidates=(
	"$HOME/.config/hypr/edit_here/source/keybinds.conf"
	"$HOME/.config/hypr/keybinds.conf"
	"$HOME/.config/hypr/bindings.conf"
	"$HOME/.config/hypr/binds.conf"
	"$HOME/.config/hypr/edit_here/keybinds.conf"
)

for candidate in "${keybind_candidates[@]}"; do
	if [[ -f "$candidate" ]]; then
		keybind_file="$candidate"
		break
	fi
done

local has_gaming_bind=false
if [[ -n "$keybind_file" ]]; then
	if grep -q "gaming-mode" "$keybind_file" 2>/dev/null; then
		has_gaming_bind=true
		fmtr::log "Gaming mode keybind already exists in $keybind_file"
	fi
fi

if [[ "$has_gaming_bind" == false && -n "$keybind_file" ]]; then
	fmtr::info "No gaming mode keybind found."
	if prmt::yes_or_no "$(fmtr::ask 'Add Super+G keybind to open gaming-mode.sh?')"; then
		# Detect terminal emulator
		local terminal="kitty"
		for term in kitty alacritty foot ghostty wezterm; do
			if command -v "$term" &>/dev/null; then
				terminal="$term"
				break
			fi
		done

		echo "" >>"$keybind_file"
		echo "# Gaming Mode" >>"$keybind_file"
		echo "bind = SUPER, G, exec, $terminal --title \"Gaming Mode\" bash -c \"cd ${SCRIPT_DIR} && ./gaming-mode.sh\"" >>"$keybind_file"
		fmtr::log "Added Super+G keybind using $terminal to $keybind_file"
		hyprctl reload 2>/dev/null || true
	fi
fi

# --- SECTION 9: Write gaming-mode.conf ---
cat >"${SCRIPT_DIR}/gaming-mode.conf" <<EOF
# Gaming Mode Configuration
# Generated by gaming-mode-setup.sh on $(date)
# Re-run gaming-mode-setup.sh to reconfigure

# User
GM_USER="${USER}"

# VM
GM_VM_NAME="${vm_name}"

# GPU PCI addresses (from config.conf)
GM_GPU_PCI="${GPU_PCI_ADDR}"
GM_GPU_AUDIO_PCI="${gpu_audio_pci}"
GM_GPU_DRIVER_ORIGINAL="${GPU_DRIVER_ORIGINAL}"

# DRM devices
GM_DRM_DGPU="${drm_dgpu}"
GM_DRM_IGPU="${drm_igpu}"

# Monitor names (from hyprctl monitors)
GM_MONITOR_DGPU="${dgpu_monitor}"
GM_MONITOR_IGPU="${igpu_monitor}"

# Resolution and refresh rates
GM_RESOLUTION="${resolution}"
GM_HZ_DGPU="${dgpu_hz}"
GM_HZ_IGPU="${igpu_hz}"

# Config file paths
GM_UWSM_ENV="${uwsm_env}"
GM_MONITORS_CONF="${monitors_conf}"
EOF

fmtr::log "Configuration saved to: ${SCRIPT_DIR}/gaming-mode.conf"

# --- SECTION 10: Show summary and confirm ---
fmtr::box_text "Configuration Summary"
cat "${SCRIPT_DIR}/gaming-mode.conf"
echo ""
fmtr::info "Review the configuration above."
fmtr::info "You can re-run gaming-mode-setup.sh at any time to reconfigure."

# Install systemd service
fmtr::info "Installing gaming-mode-daemon systemd service..."
mkdir -p "$HOME/.config/systemd/user"
cat >"$HOME/.config/systemd/user/gaming-mode-daemon.service" <<EOF
[Unit]
Description=Gaming Mode Daemon
After=default.target

[Service]
Type=simple
ExecStart=${SCRIPT_DIR}/gaming-mode-daemon.sh
Restart=on-failure
RestartSec=5
StandardOutput=append:/tmp/gaming-mode/log
StandardError=append:/tmp/gaming-mode/log

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable gaming-mode-daemon.service
systemctl --user start gaming-mode-daemon.service

fmtr::log "Setup complete! Run ./gaming-mode.sh to use gaming mode."
