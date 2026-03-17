#!/usr/bin/env bash

# =============================================================================
# Gaming Mode - Interactive Menu (Process 1)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

readonly STATE_DIR="/tmp/gaming-mode"
mkdir -p "$STATE_DIR"

# Load configuration
GAMING_MODE_CONF="${SCRIPT_DIR}/gaming-mode.conf"
if [[ ! -f "$GAMING_MODE_CONF" ]]; then
	echo "Gaming mode not configured. Run: ./gaming-mode-setup.sh"
	exit 1
fi
source "$GAMING_MODE_CONF"

# Map conf vars to script vars for readability
readonly VM_NAME="$GM_VM_NAME"
readonly GPU_PCI="$GM_GPU_PCI"
readonly GPU_AUDIO_PCI="$GM_GPU_AUDIO_PCI"
readonly DRM_IGPU="$GM_DRM_IGPU"
readonly DRM_DGPU="$GM_DRM_DGPU"
readonly MONITOR_IGPU="$GM_MONITOR_IGPU"
readonly MONITOR_DGPU="$GM_MONITOR_DGPU"
readonly UWSM_ENV="$GM_UWSM_ENV"
readonly MONITORS_CONF="$GM_MONITORS_CONF"
readonly RESOLUTION="$GM_RESOLUTION"
readonly HZ_IGPU="$GM_HZ_IGPU"
readonly HZ_DGPU="$GM_HZ_DGPU"
readonly GPU_DRIVER_ORIGINAL="${GM_GPU_DRIVER_ORIGINAL:-amdgpu}"

mkdir -p "$STATE_DIR"

get_state() {
	[[ -f "${STATE_DIR}/state" ]] && cat "${STATE_DIR}/state" || echo "unknown"
}

show_status() {
	local state
	state=$(get_state)

	echo ""
	fmtr::box_text " >> Gaming Mode << "
	echo ""

	case $state in
	idle)
		fmtr::info "Status: Idle (Linux mode)"
		;;
	starting)
		fmtr::warn "Status: Starting..."
		;;
	confirm_needed)
		fmtr::warn "Status: Confirmation needed!"
		;;
	active)
		fmtr::log "Status: Gaming Mode Active!"
		;;
	stopping)
		fmtr::warn "Status: Stopping..."
		;;
	*)
		fmtr::info "Status: Unknown"
		;;
	esac

	echo ""
	if [[ -f "${STATE_DIR}/log" ]]; then
		fmtr::info "Recent log:"
		tail -5 "${STATE_DIR}/log" 2>/dev/null | sed 's/^/  /'
	fi
	echo ""
}

check_prerequisites() {
	local vm_state gpu_driver

	vm_state=$(virsh domstate "$VM_NAME" 2>/dev/null)
	gpu_driver=$(readlink "/sys/bus/pci/devices/${GPU_PCI}/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")

	if [[ "$vm_state" != "shut off" ]]; then
		fmtr::error "VM must be shut off first"
		fmtr::info "Current VM state: $vm_state"
		return 1
	fi

	if [[ "$gpu_driver" != "$GPU_DRIVER_ORIGINAL" ]]; then
		fmtr::error "dGPU must be bound to $GPU_DRIVER_ORIGINAL"
		fmtr::info "Current driver: $gpu_driver"
		return 1
	fi

	return 0
}

start_gaming() {
	if ! check_prerequisites; then
		return 1
	fi

	echo ""
	fmtr::info "This will:"
	fmtr::info "  1. Switch Hyprland to iGPU at ${HZ_IGPU}Hz (Hyprland will restart - terminal will close)"
	fmtr::info "  2. Move dGPU to Windows VM"
	fmtr::info "  3. Start Windows VM automatically"
	fmtr::info "  4. Open Looking Glass automatically"
	echo ""
	fmtr::warn "IMPORTANT: This terminal will close when Hyprland restarts."
	fmtr::info "The process continues automatically in the background."
	fmtr::info "Open a new terminal and run gaming-mode.sh to monitor progress."
	echo ""

	if ! prmt::yes_or_no "Proceed?"; then
		fmtr::log "Cancelled by user"
		return 0
	fi

	echo "start" >"${STATE_DIR}/action"
	echo "starting" >"${STATE_DIR}/state"

	systemctl --user start gaming-mode-daemon.service 2>/dev/null || true

	fmtr::log "Daemon started. Hyprland will restart shortly."
	fmtr::info "After restart, open terminal and run gaming-mode.sh to confirm."

	return 0
}

stop_gaming() {
	echo "stop" >"${STATE_DIR}/action"

	systemctl --user start gaming-mode-daemon.service 2>/dev/null || true

	fmtr::info "Stopping gaming mode..."
	fmtr::info "Watching daemon log (Ctrl+C to detach)..."

	tail -f "${STATE_DIR}/log" 2>/dev/null &
	local tail_pid=$!

	while true; do
		sleep 2
		local state
		state=$(get_state)
		if [[ "$state" == "idle" ]]; then
			kill $tail_pid 2>/dev/null || true
			break
		fi
	done

	fmtr::log "Gaming mode stopped"
	return 0
}

confirm_screen() {
	echo ""
	fmtr::info "Screen switched to ${MONITOR_IGPU} at ${HZ_IGPU}Hz"
	fmtr::info "Does your screen look correct?"
	echo ""

	local confirm
	read -t 10 -rp "  Screen looks good? [y/n] (auto-NO in 10s): " confirm
	confirm=${confirm:-n}

	case ${confirm,,} in
	y | yes)
		touch "${STATE_DIR}/confirmed"
		fmtr::log "Confirmed. Starting VM..."
		;;
	*)
		echo "revert" >"${STATE_DIR}/action"
		fmtr::warn "Reverting changes..."
		;;
	esac
}

gaming_menu() {
	while :; do
		clear
		show_status

		local state
		state=$(get_state)

		if [[ "$state" == "confirm_needed" ]]; then
			confirm_screen
			continue
		fi

		printf '  %b[1]%b %s\n' "$TEXT_BRIGHT_GREEN" "$RESET" "Start Gaming Mode"
		printf '  %b[2]%b %s\n' "$TEXT_BRIGHT_RED" "$RESET" "Stop Gaming Mode (Emergency)"
		echo ""
		printf '  %b[0]%b %s\n\n' "$TEXT_BRIGHT_YELLOW" "$RESET" "Exit"
		printf '  %b>>%b Press Enter to refresh status\n\n' "$TEXT_BRIGHT_CYAN" "$RESET"

		local choice
		read -rp "  Enter your choice [0-2]: " choice
		clear

		case $choice in
		1)
			start_gaming
			;;
		2)
			stop_gaming
			;;
		0)
			fmtr::log "Exiting"
			exit 0
			;;
		*)
			fmtr::error "Invalid option"
			;;
		esac

		[[ -n $choice && "$choice" != "0" ]] && prmt::quick_prompt "$(fmtr::info 'Press any key to continue...')"
	done
}

gaming_menu
