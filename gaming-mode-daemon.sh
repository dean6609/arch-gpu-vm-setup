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
readonly IGPU_PCI="${GM_IGPU_PCI:-0000:08:00.0}"
readonly IGPU_AUDIO_PCI="${GM_IGPU_AUDIO_PCI:-0000:08:00.1}"
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

# Restart Hyprland via UWSM (pkill doesn't work because Restart=no in systemd service)
restart_hyprland() {
	local context="$1"
	log "Restarting Hyprland ($context)..."

	# Stop cleanly via UWSM
	if command -v uwsm &>/dev/null; then
		uwsm stop 2>/dev/null || true
	else
		pkill -x Hyprland 2>/dev/null || true
	fi

	# Wait for Hyprland to fully stop
	for i in $(seq 1 15); do
		pgrep -x Hyprland &>/dev/null || break
		sleep 1
	done

	systemctl --user reset-failed 2>/dev/null || true

	# Wait for UWSM to auto-restart Hyprland (picks up new env vars)
	for i in $(seq 1 20); do
		pgrep -x Hyprland &>/dev/null && break
		sleep 1
	done

	if pgrep -x Hyprland &>/dev/null; then
		log "Hyprland restarted ($context, PID $(pgrep -x Hyprland))"
		return 0
	else
		log "WARNING: Hyprland did not auto-restart ($context), trying manual start..."
		if command -v uwsm &>/dev/null; then
			uwsm start hyprland.desktop 2>/dev/null &
			sleep 5
		fi
		if pgrep -x Hyprland &>/dev/null; then
			log "Hyprland started manually ($context)"
			return 0
		else
			log "CRITICAL: Cannot restart Hyprland ($context)"
			return 1
		fi
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
	vm_state=$(virsh domstate "$VM_NAME")
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

	# Step 3.5: Unbind iGPU from vfio-pci and bind to amdgpu for Hyprland
	igpu_driver=$(readlink "/sys/bus/pci/devices/${IGPU_PCI}/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
	if [[ "$igpu_driver" != "amdgpu" ]]; then
		log "Step 3.5: Moving iGPU ($IGPU_PCI) from $igpu_driver to amdgpu"
		sudo "${SCRIPT_DIR}/gaming-mode-helper.sh" unbind_device "$IGPU_PCI"
		sleep 1
		sudo "${SCRIPT_DIR}/gaming-mode-helper.sh" clear_override "$IGPU_PCI"
		sleep 1
		sudo "${SCRIPT_DIR}/gaming-mode-helper.sh" bind_gpu "$IGPU_PCI" "amdgpu"
		sleep 2
		# Verify
		local new_igpu_driver
		new_igpu_driver=$(readlink "/sys/bus/pci/devices/${IGPU_PCI}/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
		log "iGPU driver: $igpu_driver -> $new_igpu_driver"
		# Also move iGPU audio companion
		if [[ -n "$IGPU_AUDIO_PCI" ]]; then
			igpu_audio_driver=$(readlink "/sys/bus/pci/devices/${IGPU_AUDIO_PCI}/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
			if [[ "$igpu_audio_driver" != "snd_hda_intel" ]]; then
				sudo "${SCRIPT_DIR}/gaming-mode-helper.sh" unbind_device "$IGPU_AUDIO_PCI"
				sleep 1
				sudo "${SCRIPT_DIR}/gaming-mode-helper.sh" clear_override "$IGPU_AUDIO_PCI"
				sleep 1
				sudo "${SCRIPT_DIR}/gaming-mode-helper.sh" bind_gpu "$IGPU_AUDIO_PCI" "snd_hda_intel"
				log "iGPU audio companion ($IGPU_AUDIO_PCI) moved to snd_hda_intel"
			fi
		fi
		# Wait for DRM device to appear
		for i in $(seq 1 10); do
			[[ -e "$DRM_IGPU" ]] && break
			sleep 1
		done
		if [[ -e "$DRM_IGPU" ]]; then
			log "iGPU DRM device $DRM_IGPU is ready"
		else
			log "WARNING: iGPU DRM device $DRM_IGPU not found after bind"
		fi
	fi

	# Step 4: Restart Hyprland on iGPU via UWSM
	if ! restart_hyprland "start-iGPU"; then
		log "CRITICAL: Cannot start Hyprland on iGPU - reverting"
		daemon_revert
		return 1
	fi

	# Step 5: Bind dGPU to vfio-pci
	log "Step 5: Binding dGPU to vfio-pci"

	if ! safe_gpu_bind "$GPU_PCI" "vfio-pci"; then
		log "FAILED to bind dGPU to vfio-pci - reverting"
		daemon_revert
		return 1
	fi
	# Bind audio device too
	if [[ -n "$GPU_AUDIO_PCI" ]]; then
		safe_gpu_bind "$GPU_AUDIO_PCI" "vfio-pci" || true
	fi

	# Release VT consoles AFTER dGPU is on vfio-pci (avoids disrupting iGPU's amdgpu)
	log "Releasing VT consoles from GPU"
	release_console

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

	# Verify Hyprland is still running on iGPU before starting VM
	if ! pgrep -x Hyprland &>/dev/null; then
		log "WARNING: Hyprland is not running! Attempting restart on iGPU..."
		safe_update_env "$UWSM_ENV" "WLR_DRM_DEVICES" "${DRM_IGPU}"
		safe_update_env "$UWSM_ENV" "AQ_DRM_DEVICES" "${DRM_IGPU}"
		if ! restart_hyprland "pre-VM-check"; then
			log "CRITICAL: Cannot start Hyprland on iGPU - reverting"
			daemon_revert
			return 1
		fi
	fi

	# Verify iGPU DRM device is accessible
	if [[ -n "$DRM_IGPU" && ! -e "$DRM_IGPU" ]]; then
		log "WARNING: iGPU DRM device $DRM_IGPU not found"
		log "Current iGPU driver: $(readlink /sys/bus/pci/devices/${IGPU_PCI}/driver 2>/dev/null | xargs basename 2>/dev/null || echo 'none')"
	fi

	log "Hyprland running (PID $(pgrep -x Hyprland)), iGPU DRM: $DRM_IGPU"

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
	restart_hyprland "stop-dGPU"

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
	restart_hyprland "revert-dGPU"

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
