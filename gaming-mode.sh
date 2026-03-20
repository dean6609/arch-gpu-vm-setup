#!/usr/bin/env bash

# =============================================================================
# Gaming Mode - Interactive Menu (Process 1)
# Communicates with gaming-mode-daemon.sh via /tmp/gaming-mode/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

# Ensure virsh commands always connect to the system qemu daemon
export LIBVIRT_DEFAULT_URI="qemu:///system"

# Load configuration (run setup wizard if missing)
GAMING_MODE_CONF="${SCRIPT_DIR}/gaming-mode.conf"
if [[ ! -f "$GAMING_MODE_CONF" ]]; then
	fmtr::warn "Gaming mode not configured."
	fmtr::info "Running setup wizard..."
	"${SCRIPT_DIR}/gaming-mode-setup.sh" || exit 1
	# Re-check after wizard
	if [[ ! -f "$GAMING_MODE_CONF" ]]; then
		fmtr::error "Setup wizard did not create gaming-mode.conf"
		exit 1
	fi
fi
source "$GAMING_MODE_CONF"

# Map conf variables to local constants
readonly VM_NAME="${GM_VM_NAME:-WindowsVM}"
readonly GPU_PCI="${GM_GPU_PCI}"
readonly GPU_AUDIO_PCI="${GM_GPU_AUDIO_PCI}"
readonly DRM_DGPU="${GM_DRM_DGPU}"
readonly DRM_IGPU="${GM_DRM_IGPU}"
readonly MONITOR_IGPU="${GM_MONITOR_IGPU}"
readonly MONITOR_DGPU="${GM_MONITOR_DGPU}"
readonly UWSM_ENV="${GM_UWSM_ENV}"
readonly MONITORS_CONF="${GM_MONITORS_CONF}"
readonly RESOLUTION="${GM_RESOLUTION:-1920x1080}"
readonly HZ_IGPU="${GM_HZ_IGPU:-60}"
readonly HZ_DGPU="${GM_HZ_DGPU:-240}"
readonly GPU_ORIGINAL_DRIVER="${GM_GPU_ORIGINAL_DRIVER:-${GM_GPU_DRIVER_ORIGINAL:-amdgpu}}"
readonly STATE_DIR="/tmp/gaming-mode"

mkdir -p "$STATE_DIR"

# =============================================================================
# Helper Functions
# =============================================================================

get_state() {
	[[ -f "${STATE_DIR}/state" ]] && cat "${STATE_DIR}/state" 2>/dev/null || echo "unknown"
}

get_gpu_driver_current() {
	readlink "/sys/bus/pci/devices/${GPU_PCI}/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none"
}

get_vm_state() {
	virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown"
}

ensure_daemon_running() {
	if ! systemctl --user is-active gaming-mode-daemon.service &>/dev/null; then
		fmtr::info "Starting gaming mode daemon..."
		systemctl --user start gaming-mode-daemon.service 2>/dev/null || true
		sleep 1
	fi
}

# =============================================================================
# Status Display
# =============================================================================

show_status() {
	local state
	state=$(get_state)

	echo ""
	fmtr::box_text " >> Gaming Mode << "
	echo ""

	# State display
	case $state in
	idle)
		fmtr::info "Status: Idle (Linux mode)"
		;;
	starting)
		fmtr::warn "Status: Starting gaming mode..."
		;;
	confirm_needed)
		fmtr::warn "Status: CONFIRMATION NEEDED"
		;;
	active)
		fmtr::log "Status: Gaming Mode ACTIVE"
		;;
	stopping)
		fmtr::warn "Status: Stopping gaming mode..."
		;;
	*)
		fmtr::info "Status: Unknown ($state)"
		;;
	esac

	# Additional info
	local gpu_driver vm_state daemon_status
	gpu_driver=$(get_gpu_driver_current)
	vm_state=$(get_vm_state)
	daemon_status="stopped"
	systemctl --user is-active gaming-mode-daemon.service &>/dev/null && daemon_status="running"

	echo ""
	printf '  GPU Driver:  %s\n' "$gpu_driver"
	printf '  VM State:    %s\n' "$vm_state"
	printf '  Daemon:      %s\n' "$daemon_status"

	# Recent log
	if [[ -f "${STATE_DIR}/log" ]]; then
		echo ""
		fmtr::info "Recent log:"
		tail -5 "${STATE_DIR}/log" 2>/dev/null | sed 's/^/    /'
	fi
	echo ""
}

# =============================================================================
# Prerequisites Check
# =============================================================================

check_prerequisites() {
	local vm_state gpu_driver

	vm_state=$(get_vm_state)
	gpu_driver=$(get_gpu_driver_current)

	if [[ "$vm_state" != "shut off" ]]; then
		fmtr::error "VM '$VM_NAME' must be shut off first."
		fmtr::info "Current VM state: $vm_state"
		return 1
	fi

	if [[ "$gpu_driver" != "$GPU_ORIGINAL_DRIVER" ]]; then
		fmtr::error "dGPU must be bound to $GPU_ORIGINAL_DRIVER (not $gpu_driver)"
		return 1
	fi

	# Ensure daemon is running
	ensure_daemon_running

	return 0
}

# =============================================================================
# Start Gaming
# =============================================================================

start_gaming() {
	if ! check_prerequisites; then
		return 1
	fi

	echo ""
	fmtr::warn "WARNING: This will:"
	fmtr::info "  1. Transfer your dGPU to the Windows VM"
	fmtr::info "  2. Hyprland will restart briefly (your desktop will flicker)"
	fmtr::info "  3. After restart, switch your monitor input to HDMI/motherboard"
	fmtr::info "  4. Open this menu again (Super+G or ./gaming-mode.sh) to confirm"
	fmtr::info "  5. The VM will start automatically after confirmation"
	fmtr::info "  6. Use two ALT keys to capture/release keyboard/mouse"
	echo ""

	if ! prmt::yes_or_no "$(fmtr::ask 'Proceed with starting gaming mode?')"; then
		fmtr::log "Cancelled by user"
		return 0
	fi

	# Write action for daemon
	echo "start" >"${STATE_DIR}/action"
	echo "starting" >"${STATE_DIR}/state"

	# Ensure daemon is running
	ensure_daemon_running

	echo ""
	fmtr::log "Process started. Hyprland will restart shortly."
	fmtr::info "After restart, open gaming-mode.sh (Super+G) and confirm screen looks good."
	fmtr::info "(This terminal will close when Hyprland restarts - this is normal)"
	echo ""

	sleep 2
	exit 0
}

# =============================================================================
# Stop Gaming
# =============================================================================

stop_gaming() {
	echo "stop" >"${STATE_DIR}/action"

	ensure_daemon_running

	fmtr::info "Stopping gaming mode..."
	fmtr::info "The daemon will shut down the VM and restore your GPU."
	fmtr::info "Hyprland will restart on the dGPU."
	echo ""
	fmtr::info "Watching progress..."
	echo ""

	# Show progress until idle
	local count=0
	while ((count < 120)); do
		local state
		state=$(get_state)
		if [[ "$state" == "idle" ]]; then
			echo ""
			fmtr::log "Gaming mode stopped!"
			fmtr::info "Switch your monitor input to ${MONITOR_DGPU} for ${HZ_DGPU}Hz"
			return 0
		fi
		# Show last log line
		local last_log
		last_log=$(tail -1 "${STATE_DIR}/log" 2>/dev/null)
		printf '\r  [%s] %s          ' "$(date +%H:%M:%S)" "${last_log:0:60}"
		sleep 2
		((count += 2))
	done

	echo ""
	fmtr::warn "Timeout waiting for stop. Check daemon status."
}

# =============================================================================
# Confirm Screen (after GPU switch)
# =============================================================================

confirm_screen() {
	echo ""
	fmtr::box_text " Screen Confirmation "
	echo ""
	fmtr::info "Your screen should now be on ${MONITOR_IGPU} (iGPU) at ${HZ_IGPU}Hz"
	fmtr::info "If you can see this message, the switch worked correctly."
	echo ""
	fmtr::warn "Answer YES to continue starting the Windows VM."
	fmtr::warn "Answer NO (or wait 120 seconds) to revert everything."
	echo ""

	local confirm
	read -t 120 -rp "  Screen looks good? [y/n] (auto-NO in 120s): " confirm
	echo ""
	confirm=${confirm:-n}

	case $(echo "$confirm" | tr '[:upper:]' '[:lower:]') in
	y | yes)
		touch "${STATE_DIR}/confirmed"
		fmtr::log "Confirmed! Starting VM..."
		fmtr::info "VM will boot in ~40 seconds. Switch monitor to ${MONITOR_DGPU} to play."
		sleep 3
		;;
	*)
		echo "revert" >"${STATE_DIR}/action"
		fmtr::warn "Reverting changes..."
		fmtr::info "Hyprland will restart on dGPU shortly."
		sleep 3
		;;
	esac
}

# =============================================================================
# Main Menu
# =============================================================================

gaming_menu() {
	while :; do
		clear

		# Check state BEFORE showing menu
		local state
		state=$(get_state)

		# Handle special states automatically
		if [[ "$state" == "confirm_needed" ]]; then
			show_status
			confirm_screen
			continue
		fi

		if [[ "$state" == "starting" || "$state" == "stopping" ]]; then
			show_status
			fmtr::info "Operation in progress... auto-refreshing every 3 seconds"
			read -t 3 -rp "  (Press Enter to refresh now): " || true
			continue
		fi

		# Normal menu
		show_status

		if [[ "$state" == "active" ]]; then
			fmtr::log "Gaming Mode is ACTIVE"
			fmtr::info "The Windows VM is running with your dGPU."
			fmtr::info "Switch your monitor to ${MONITOR_DGPU} to play."
			echo ""
			printf '  %b[2]%b %s\n' "$TEXT_BRIGHT_RED" "$RESET" "Stop Gaming Mode"
			printf '  %b[3]%b %s\n' "$TEXT_BRIGHT_CYAN" "$RESET" "Re-run Setup Wizard"
			printf '  %b[0]%b %s\n\n' "$TEXT_BRIGHT_YELLOW" "$RESET" "Exit (leave gaming active)"
		else
			printf '  %b[1]%b %s\n' "$TEXT_BRIGHT_GREEN" "$RESET" "Start Gaming Mode"
			printf '  %b[2]%b %s\n' "$TEXT_BRIGHT_RED" "$RESET" "Stop Gaming Mode (Emergency)"
			printf '  %b[3]%b %s\n' "$TEXT_BRIGHT_CYAN" "$RESET" "Run Setup Wizard"
			echo ""
			printf '  %b[0]%b %s\n\n' "$TEXT_BRIGHT_YELLOW" "$RESET" "Exit"
		fi

		printf '  %b>>%b Press Enter to refresh status\n\n' "$TEXT_BRIGHT_CYAN" "$RESET"

		local choice
		read -rp "  Enter your choice [0-2]: " choice

		case $choice in
		1)
			if [[ "$state" == "active" ]]; then
				fmtr::warn "Gaming mode is already active. Use option 2 to stop."
			else
				start_gaming
			fi
			;;
		2)
			stop_gaming
			;;
		3)
			fmtr::box_text "Gaming Mode Setup"
			"${SCRIPT_DIR}/gaming-mode-setup.sh"
			# Refresh configuration after setup
			source "$GAMING_MODE_CONF"
			;;
		0)
			fmtr::log "Exiting"
			exit 0
			;;
		"")
			# Empty input = refresh
			continue
			;;
		*)
			fmtr::error "Invalid option"
			;;
		esac

		[[ -n "$choice" && "$choice" != "0" ]] && prmt::quick_prompt "$(fmtr::info 'Press any key to continue...')"
	done
}

gaming_menu
