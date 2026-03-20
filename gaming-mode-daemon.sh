#!/usr/bin/env bash

# =============================================================================
# Gaming Mode Daemon (Process 2)
# Background systemd service that handles GPU/VM operations
# Survives Hyprland restarts. Communicates via /tmp/gaming-mode/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure virsh commands always connect to the system qemu daemon
# This is critical for systemd user services which default to qemu:///session
export LIBVIRT_DEFAULT_URI="qemu:///system"

readonly STATE_DIR="/tmp/gaming-mode"

# Load configuration
GAMING_MODE_CONF="${SCRIPT_DIR}/gaming-mode.conf"
if [[ ! -f "$GAMING_MODE_CONF" ]]; then
	echo "gaming-mode.conf not found. Run gaming-mode-setup.sh first."
	exit 1
fi
source "$GAMING_MODE_CONF"

# Map conf variables to local constants
readonly VM_NAME="${GM_VM_NAME:-WindowsVM}"
readonly GPU_PCI="${GM_GPU_PCI}"
readonly GPU_AUDIO_PCI="${GM_GPU_AUDIO_PCI}"
readonly DRM_IGPU="${GM_DRM_IGPU}"
readonly DRM_DGPU="${GM_DRM_DGPU}"
readonly MONITOR_IGPU="${GM_MONITOR_IGPU}"
readonly MONITOR_DGPU="${GM_MONITOR_DGPU}"
readonly UWSM_ENV="${GM_UWSM_ENV}"
readonly MONITORS_CONF="${GM_MONITORS_CONF}"
readonly RESOLUTION="${GM_RESOLUTION:-1920x1080}"
readonly HZ_IGPU="${GM_HZ_IGPU:-60}"
readonly HZ_DGPU="${GM_HZ_DGPU:-240}"
readonly GPU_ORIGINAL_DRIVER="${GM_GPU_ORIGINAL_DRIVER:-${GM_GPU_DRIVER_ORIGINAL:-amdgpu}}"
readonly GPU_AUDIO_ORIGINAL_DRIVER="${GM_GPU_AUDIO_ORIGINAL_DRIVER:-snd_hda_intel}"

# =============================================================================
# Logging
# =============================================================================

log() {
	local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
	echo "$msg" >>"${STATE_DIR}/log"
	echo "$msg"
}

# =============================================================================
# Safe GPU Bind (CRITICAL function)
# =============================================================================

release_console() {
	sudo "${SCRIPT_DIR}/gaming-mode-helper.sh" release_console
}

bind_console() {
	sudo "${SCRIPT_DIR}/gaming-mode-helper.sh" bind_console
}

safe_gpu_bind() {
	local pci_addr="$1"
	local target_driver="$2"
	local sys_path="/sys/bus/pci/devices/${pci_addr}"

	local current
	current=$(readlink "${sys_path}/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")

	[[ "$current" == "$target_driver" ]] && return 0

	log "Binding $pci_addr: $current -> $target_driver"

	sudo "${SCRIPT_DIR}/gaming-mode-helper.sh" bind_gpu "$pci_addr" "$target_driver"

	local new_driver
	new_driver=$(readlink "${sys_path}/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")

	if [[ "$new_driver" == "$target_driver" ]]; then
		log "Successfully bound $pci_addr to $target_driver"
		return 0
	else
		log "FAILED to bind $pci_addr to $target_driver (current: $new_driver)"
		return 1
	fi
}

# =============================================================================
# UWSM Env Update Helper
# =============================================================================

safe_update_env() {
	local file="$1"
	local var="$2"
	local value="$3"

	if [[ ! -f "$file" ]]; then
		log "ERROR: $file not found"
		return 1
	fi

	if grep -q "^export ${var}=" "$file" 2>/dev/null; then
		sed -i "s|${var}=.*|${var}=${value}|" "$file"
		log "Updated $var=$value in $file"
	else
		echo "export ${var}=${value}" >>"$file"
		log "Added $var=$value to $file"
	fi
}

# =============================================================================
# Start Gaming Mode
# =============================================================================

daemon_start_gaming() {
	log "=== STARTING GAMING MODE ==="

	# Verify preconditions
	log "Verifying preconditions..."

	local vm_state
	vm_state=$(virsh domstate "$VM_NAME" 2>/dev/null)
	if [[ "$vm_state" != "shut off" ]]; then
		log "ERROR: VM must be shut off (current: $vm_state)"
		echo "idle" >"${STATE_DIR}/state"
		return 1
	fi

	local current_driver
	current_driver=$(readlink "/sys/bus/pci/devices/${GPU_PCI}/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
	if [[ "$current_driver" != "$GPU_ORIGINAL_DRIVER" ]]; then
		log "ERROR: GPU must be bound to $GPU_ORIGINAL_DRIVER (current: $current_driver)"
		echo "idle" >"${STATE_DIR}/state"
		return 1
	fi

	if [[ ! -f "$UWSM_ENV" ]]; then
		log "ERROR: $UWSM_ENV not found"
		echo "idle" >"${STATE_DIR}/state"
		return 1
	fi

	log "All preconditions met"

	# Step 1: Update UWSM env to iGPU
	log "Step 1: Updating display config to iGPU"
	safe_update_env "$UWSM_ENV" "WLR_DRM_DEVICES" "${DRM_IGPU}"
	safe_update_env "$UWSM_ENV" "AQ_DRM_DEVICES" "${DRM_IGPU}"

	# Step 2: Update monitors.conf to iGPU
	log "Step 2: Updating monitors.conf to ${MONITOR_IGPU}@${HZ_IGPU}Hz"
	echo "monitor = ${MONITOR_IGPU},${RESOLUTION}@${HZ_IGPU},0x0,1" >"$MONITORS_CONF" 2>/dev/null || {
		log "ERROR: Failed to update monitors.conf"
	}

	# Step 3: Load vfio modules if not loaded
	log "Step 3: Loading vfio modules"
	sudo "${SCRIPT_DIR}/gaming-mode-helper.sh" load_vfio
	sleep 1
	log "VFIO modules loaded"

	# Step 4: Restart Hyprland (UWSM will restart it on iGPU)
	log "Step 4: Killing Hyprland to free dGPU - UWSM will restart it on iGPU..."
	pkill -x Hyprland 2>/dev/null || true
	log "Waiting for Hyprland to release dGPU..."
	sleep 8
	
	# Clear failed units caused by killing the compositor abruptly
	systemctl --user reset-failed 2>/dev/null || true

	# Step 5: Bind dGPU to vfio-pci
	log "Step 5: Binding dGPU to vfio-pci"
	log "Releasing VT consoles from GPU"
	release_console

	if ! safe_gpu_bind "$GPU_PCI" "vfio-pci"; then
		log "FAILED to bind dGPU to vfio-pci - reverting"
		daemon_revert
		return 1
	fi
	# Bind audio device too
	if [[ -n "$GPU_AUDIO_PCI" ]]; then
		safe_gpu_bind "$GPU_AUDIO_PCI" "vfio-pci" || true
	fi

	log "Hyprland recovery wait complete"
	sleep 7

	# Step 6: Write confirm_needed state
	echo "confirm_needed" >"${STATE_DIR}/state"
	log "Step 6: Waiting for user confirmation (120 seconds timeout)"

	# Step 7: Wait for confirmation with 120 second timeout
	local waited=0
	while ((waited < 120)); do
		if [[ -f "${STATE_DIR}/confirmed" ]]; then
			rm -f "${STATE_DIR}/confirmed"
			log "User confirmed - proceeding to start VM"
			break
		fi
		# Check if user wrote "revert" action
		if [[ -f "${STATE_DIR}/action" ]]; then
			local pending_action
			pending_action=$(cat "${STATE_DIR}/action" 2>/dev/null)
			if [[ "$pending_action" == "revert" ]]; then
				rm -f "${STATE_DIR}/action"
				log "User requested revert"
				daemon_revert
				return
			fi
		fi
		sleep 1
		((waited++))
	done

	if ((waited >= 120)); then
		log "No confirmation received after 120s - auto-reverting"
		daemon_revert
		return
	fi

	# Step 8: Start VM
	log "Step 8: Starting Windows VM..."
	echo "active" >"${STATE_DIR}/state"
	
	# Create a TCP audio bridge on localhost to bypass UID/permission issues
	# This is the most robust way to share audio without manual cookie hacks
	pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 &>/dev/null
	
	if ! virsh start "$VM_NAME" 2>>"${STATE_DIR}/log"; then
		log "Failed to start VM - reverting"
		daemon_revert
		return
	fi
	log "VM started - waiting 10 seconds for initialization..."
	sleep 10

	# Step 9: Setup kvmfr and launch Looking Glass
	log "Step 9: Setting up Looking Glass"
	sudo "${SCRIPT_DIR}/gaming-mode-helper.sh" setup_kvmfr "$GM_USER"

	# Launch Looking Glass if available
	if command -v looking-glass-client &>/dev/null; then
		looking-glass-client 2>/dev/null &
		log "Looking Glass launched (use Right Ctrl to capture/release input)"
	else
		log "looking-glass-client not found - skipping"
	fi

	log "=== GAMING MODE ACTIVE ==="
	log "Switch your monitor input to ${MONITOR_DGPU} to play"
	log "Use gaming-mode.sh option 2 to stop"
}

# =============================================================================
# Stop Gaming Mode (NO REBOOT REQUIRED)
# =============================================================================

daemon_stop_gaming() {
	log "=== STOPPING GAMING MODE ==="
	echo "stopping" >"${STATE_DIR}/state"

	# Step 1: Shutdown VM
	log "Step 1: Shutting down VM..."
	virsh shutdown "$VM_NAME" 2>/dev/null || true

	local waited=0
	while ((waited < 60)); do
		[[ "$(virsh domstate "$VM_NAME" 2>/dev/null)" == "shut off" ]] && break
		sleep 1
		((waited++))
	done

	if [[ "$(virsh domstate "$VM_NAME" 2>/dev/null)" != "shut off" ]]; then
		log "Force destroying VM..."
		virsh destroy "$VM_NAME" 2>/dev/null || true
		sleep 3
	fi
	log "VM stopped"

	# Step 2: Restore dGPU from vfio-pci to original driver
	log "Step 2: Restoring GPU to $GPU_ORIGINAL_DRIVER"
	if ! safe_gpu_bind "$GPU_PCI" "$GPU_ORIGINAL_DRIVER"; then
		log "WARNING: Failed to restore dGPU driver - manual reboot may be needed"
	fi
	if [[ -n "$GPU_AUDIO_PCI" ]]; then
		safe_gpu_bind "$GPU_AUDIO_PCI" "$GPU_AUDIO_ORIGINAL_DRIVER" || true
	fi
	
	log "Binding VT consoles back to GPU"
	bind_console
	
	log "GPU restored to $GPU_ORIGINAL_DRIVER"

	# Step 3: Update UWSM env back to dGPU
	log "Step 3: Restoring display config to dGPU"
	safe_update_env "$UWSM_ENV" "WLR_DRM_DEVICES" "${DRM_DGPU}"
	safe_update_env "$UWSM_ENV" "AQ_DRM_DEVICES" "${DRM_DGPU}"

	# Step 4: Update monitors.conf back to dGPU at full hz
	echo "monitor = ${MONITOR_DGPU},${RESOLUTION}@${HZ_DGPU},0x0,1" >"$MONITORS_CONF" 2>/dev/null || {
		log "ERROR: Failed to update monitors.conf"
	}

	# Step 5: Restart Hyprland on dGPU
	log "Step 5: Restarting Hyprland on dGPU..."
	pkill -x Hyprland 2>/dev/null || true
	sleep 15

	# Step 6: Verify Hyprland restarted
	local attempts=0
	while ((attempts < 10)); do
		pgrep -x Hyprland &>/dev/null && break
		sleep 2
		((attempts++))
	done

	if pgrep -x Hyprland &>/dev/null; then
		log "Hyprland restarted successfully on dGPU"
		log "Switch your monitor input back to ${MONITOR_DGPU} for ${HZ_DGPU}Hz"
	else
		log "WARNING: Hyprland may not have restarted"
		log "If screen is black, switch monitor to ${MONITOR_DGPU}"
		log "Hyprland should restart automatically via UWSM"
	fi

	echo "idle" >"${STATE_DIR}/state"
	log "=== GAMING MODE STOPPED ==="
	log "IMPORTANT: Switch your monitor input to ${MONITOR_DGPU} for ${HZ_DGPU}Hz"
}

# =============================================================================
# Revert (same as stop but without VM shutdown)
# =============================================================================

daemon_revert() {
	log "=== REVERTING CHANGES ==="
	echo "stopping" >"${STATE_DIR}/state"

	# Restore GPU
	log "Restoring GPU to $GPU_ORIGINAL_DRIVER"
	safe_gpu_bind "$GPU_PCI" "$GPU_ORIGINAL_DRIVER" || {
		log "WARNING: Failed to restore dGPU driver"
	}
	if [[ -n "$GPU_AUDIO_PCI" ]]; then
		safe_gpu_bind "$GPU_AUDIO_PCI" "$GPU_AUDIO_ORIGINAL_DRIVER" || true
	fi

	log "Binding VT consoles back to GPU"
	bind_console

	# Restore UWSM env
	safe_update_env "$UWSM_ENV" "WLR_DRM_DEVICES" "${DRM_DGPU}"
	safe_update_env "$UWSM_ENV" "AQ_DRM_DEVICES" "${DRM_DGPU}"

	# Restore monitors.conf
	echo "monitor = ${MONITOR_DGPU},${RESOLUTION}@${HZ_DGPU},0x0,1" >"$MONITORS_CONF" 2>/dev/null || true

	# Restart Hyprland
	log "Restarting Hyprland on dGPU..."
	pkill -x Hyprland 2>/dev/null || true
	sleep 15

	# Verify
	local attempts=0
	while ((attempts < 10)); do
		pgrep -x Hyprland &>/dev/null && break
		sleep 2
		((attempts++))
	done

	if pgrep -x Hyprland &>/dev/null; then
		log "Hyprland restarted on dGPU"
	else
		log "WARNING: Hyprland may not have restarted - check monitor input"
	fi

	echo "idle" >"${STATE_DIR}/state"
	# Unload TCP audio module
	pactl unload-module $(pactl list modules short | grep "module-native-protocol-tcp" | awk '{print $1}') &>/dev/null || true
	
	log "=== REVERT COMPLETE ==="
}

# =============================================================================
# Main Daemon Loop
# =============================================================================

mkdir -p "$STATE_DIR"
echo "idle" >"${STATE_DIR}/state"
: >"${STATE_DIR}/log"

log "Gaming Mode Daemon started (PID $$)"
log "VM: $VM_NAME | GPU: $GPU_PCI | iGPU DRM: $DRM_IGPU | dGPU DRM: $DRM_DGPU"

while true; do
	if [[ -f "${STATE_DIR}/action" ]]; then
		# Read and DELETE action file BEFORE executing (prevents re-execution)
		action=$(cat "${STATE_DIR}/action" 2>/dev/null)
		rm -f "${STATE_DIR}/action"

		case "$action" in
		start)
			daemon_start_gaming
			;;
		stop)
			daemon_stop_gaming
			;;
		revert)
			daemon_revert
			;;
		*)
			log "Unknown action: $action"
			;;
		esac
	fi
	sleep 2
done
