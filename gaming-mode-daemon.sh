#!/usr/bin/env bash

# =============================================================================
# Gaming Mode Daemon (Process 2)
# Background service that handles GPU/VM operations
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

readonly STATE_DIR="/tmp/gaming-mode"

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

log() {
	local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
	echo "$msg" >>"${STATE_DIR}/log"
	echo "$msg"
}

safe_gpu_bind() {
	local pci_addr="$1"
	local target_driver="$2"
	local sys_path="/sys/bus/pci/devices/${pci_addr}"

	local current
	current=$(readlink "${sys_path}/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")

	[[ "$current" == "$target_driver" ]] && return 0

	if [[ "$current" != "none" ]]; then
		echo "${pci_addr}" >"/sys/bus/pci/drivers/${current}/unbind" 2>/dev/null || true
		sleep 0.5
	fi

	echo -n >"${sys_path}/driver_override" 2>/dev/null || true
	sleep 0.5
	echo "${target_driver}" >"${sys_path}/driver_override"
	sleep 0.5
	echo "${pci_addr}" >"/sys/bus/pci/drivers/${target_driver}/bind"
	sleep 0.5

	local new_driver
	new_driver=$(readlink "${sys_path}/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
	[[ "$new_driver" == "$target_driver" ]]
}

daemon_start_gaming() {
	log "=== STARTING GAMING MODE ==="

	log "Step 1: Updating display config to iGPU"
	sed -i "s|WLR_DRM_DEVICES=.*|WLR_DRM_DEVICES=${DRM_IGPU}|" "$UWSM_ENV" 2>/dev/null || true
	sed -i "s|AQ_DRM_DEVICES=.*|AQ_DRM_DEVICES=${DRM_IGPU}|" "$UWSM_ENV" 2>/dev/null || true
	echo "monitor = ${MONITOR_IGPU},${RESOLUTION}@${HZ_IGPU},0x0,1" >"$MONITORS_CONF" 2>/dev/null || true
	log "Display config updated to iGPU ${HZ_IGPU}Hz"

	log "Step 2: Loading vfio modules"
	modprobe vfio vfio-pci vfio_iommu_type1 2>/dev/null || true
	log "VFIO modules loaded"

	log "Step 3: Binding dGPU to vfio-pci"
	safe_gpu_bind "$GPU_PCI" "vfio-pci"
	safe_gpu_bind "$GPU_AUDIO_PCI" "vfio-pci"
	log "dGPU bound to vfio-pci"
	log "Restarting Hyprland to switch to iGPU..."
	pkill -x Hyprland 2>/dev/null || true
	sleep 15
	log "Hyprland recovery wait complete"

	log "Step 5: Waiting for user confirmation"
	echo "confirm_needed" >"${STATE_DIR}/state"
	log "Open gaming-mode.sh and confirm screen looks good"

	local waited=0
	while ((waited < 30)); do
		if [[ -f "${STATE_DIR}/confirmed" ]]; then
			rm "${STATE_DIR}/confirmed"
			log "User confirmed screen looks good"
			break
		fi
		if [[ -f "${STATE_DIR}/action" ]]; then
			local action
			action=$(cat "${STATE_DIR}/action" 2>/dev/null)
			if [[ "$action" == "revert" ]]; then
				rm "${STATE_DIR}/action" 2>/dev/null || true
				log "User requested revert"
				daemon_revert
				return
			fi
		fi
		sleep 1
		((waited++))
	done

	if ((waited >= 30)); then
		log "No confirmation received, auto-reverting..."
		daemon_revert
		return
	fi

	log "Step 6: Starting Windows VM"
	echo "active" >"${STATE_DIR}/state"
	virsh start "$VM_NAME" 2>/dev/null || log "Failed to start VM"
	log "VM started, waiting 40 seconds for boot..."
	sleep 40

	log "Step 7: Loading kvmfr and launching Looking Glass"
	modprobe kvmfr static_size_mb=64 2>/dev/null || true
	sleep 1
	chown "${GM_USER}:kvm" /dev/kvmfr0 2>/dev/null || true
	looking-glass-client &
	log "Looking Glass launched"
	log "Switch monitor to DP1 to play"
	log "Run gaming-mode.sh and select Stop when done"

	log "=== GAMING MODE ACTIVE ==="
}

daemon_stop_gaming() {
	log "=== STOPPING GAMING MODE ==="
	echo "stopping" >"${STATE_DIR}/state"

	log "Step 1: Shutting down VM"
	virsh shutdown "$VM_NAME" 2>/dev/null || true
	local waited=0
	while ((waited < 60)); do
		[[ "$(virsh domstate "$VM_NAME" 2>/dev/null)" == "shut off" ]] && break
		sleep 1
		((waited++))
	done
	if [[ "$(virsh domstate "$VM_NAME" 2>/dev/null)" != "shut off" ]]; then
		virsh destroy "$VM_NAME" 2>/dev/null || true
		sleep 2
	fi
	log "VM stopped"

	log "Step 2: Restoring GPU to $GPU_DRIVER_ORIGINAL"
	safe_gpu_bind "$GPU_PCI" "$GPU_DRIVER_ORIGINAL"
	safe_gpu_bind "$GPU_AUDIO_PCI" "snd_hda_intel"
	log "GPU restored to $GPU_DRIVER_ORIGINAL"

	log "Step 3: Restoring display config"
	sed -i "s|WLR_DRM_DEVICES=.*|WLR_DRM_DEVICES=${DRM_DGPU}|" "$UWSM_ENV" 2>/dev/null || true
	sed -i "s|AQ_DRM_DEVICES=.*|AQ_DRM_DEVICES=${DRM_DGPU}|" "$UWSM_ENV" 2>/dev/null || true
	echo "monitor = ${MONITOR_DGPU},${RESOLUTION}@${HZ_DGPU},0x0,1" >"$MONITORS_CONF" 2>/dev/null || true
	log "Display config restored to dGPU ${HZ_DGPU}Hz"
	log "Restarting Hyprland to switch back to dGPU..."
	pkill -x Hyprland 2>/dev/null || true
	sleep 15
	log "Done. Switch monitor to DP1 for ${HZ_DGPU}Hz"

	echo "idle" >"${STATE_DIR}/state"
	log "=== GAMING MODE STOPPED ==="
}

daemon_revert() {
	log "=== REVERTING CHANGES ==="

	log "Step 1: Restoring GPU to $GPU_DRIVER_ORIGINAL"
	safe_gpu_bind "$GPU_PCI" "$GPU_DRIVER_ORIGINAL"
	safe_gpu_bind "$GPU_AUDIO_PCI" "snd_hda_intel"
	log "GPU restored to $GPU_DRIVER_ORIGINAL"

	log "Step 2: Restoring display config"
	sed -i "s|WLR_DRM_DEVICES=.*|WLR_DRM_DEVICES=${DRM_DGPU}|" "$UWSM_ENV" 2>/dev/null || true
	sed -i "s|AQ_DRM_DEVICES=.*|AQ_DRM_DEVICES=${DRM_DGPU}|" "$UWSM_ENV" 2>/dev/null || true
	echo "monitor = ${MONITOR_DGPU},${RESOLUTION}@${HZ_DGPU},0x0,1" >"$MONITORS_CONF" 2>/dev/null || true
	log "Display config restored to dGPU ${HZ_DGPU}Hz"
	log "Restarting Hyprland to switch back to dGPU..."
	pkill -x Hyprland 2>/dev/null || true
	sleep 15

	echo "idle" >"${STATE_DIR}/state"
	log "=== REVERT COMPLETE ==="
}

mkdir -p "$STATE_DIR"
echo "idle" >"${STATE_DIR}/state"
: >"${STATE_DIR}/log"

log "Gaming Mode Daemon started"

while true; do
	if [[ -f "${STATE_DIR}/action" ]]; then
		action=$(cat "${STATE_DIR}/action")
		rm -f "${STATE_DIR}/action"

		case $action in
		start)
			daemon_start_gaming
			;;
		stop)
			daemon_stop_gaming
			;;
		revert)
			daemon_revert
			;;
		esac
	fi
	sleep 2
done
