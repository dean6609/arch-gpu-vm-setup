#!/usr/bin/env bash

# =============================================================================
# Module 04: GPU Binding Management
# Dynamic bind/unbind GPU to vfio-pci or original driver (vm/host/none modes)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

gpu_mode_vm() {
	local pci_addr="$1"

	fmtr::info "Binding GPU $pci_addr to vfio-pci (VM mode)..."

	local current_driver
	current_driver=$(get_gpu_driver "$pci_addr")

	if [[ "$current_driver" == "nvidia" ]]; then
		fmtr::info "Unloading NVIDIA modules..."
		rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true
	fi

	if [[ -e "/sys/bus/pci/devices/$pci_addr/driver" ]]; then
		echo "$pci_addr" >/sys/bus/pci/devices/"$pci_addr"/driver/unbind 2>/dev/null || true
	fi

	echo "vfio-pci" >/sys/bus/pci/devices/"$pci_addr"/driver_override
	echo "$pci_addr" >/sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null &&
		fmtr::log "GPU bound to vfio-pci" ||
		fmtr::error "Failed to bind GPU to vfio-pci"

	local iommu_group
	iommu_group=$(get_iommu_group "$pci_addr")

	if [[ -n "$iommu_group" ]]; then
		local -a group_devices
		while IFS= read -r dev; do
			[[ -n "$dev" ]] || continue
			[[ "$dev" == "$pci_addr" ]] && continue

			local dev_class
			dev_class=$(cat "/sys/bus/pci/devices/$dev/class" 2>/dev/null)
			dev_class=${dev_class#0x}

			if [[ "$dev_class" == "0604" ]]; then
				fmtr::info "Skipping PCI bridge: $dev"
				continue
			fi

			local dev_driver
			dev_driver=$(get_gpu_driver "$dev")

			if [[ -n "$dev_driver" && "$dev_driver" != "vfio-pci" ]]; then
				echo "$dev" >/sys/bus/pci/devices/"$dev"/driver/unbind 2>/dev/null || true
			fi

			echo "vfio-pci" >/sys/bus/pci/devices/"$dev"/driver_override 2>/dev/null || true
			echo "$dev" >/sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
			fmtr::log "Bound companion device: $dev"
		done < <(get_iommu_group_devices "$iommu_group")
	fi

	fmtr::log "GPU $pci_addr is now bound to vfio-pci for VM passthrough"
}

gpu_mode_host() {
	local pci_addr="$1"
	local original_driver="${2:-nvidia}"

	fmtr::info "Binding GPU $pci_addr to $original_driver (host mode)..."

	echo "$pci_addr" >/sys/bus/pci/devices/"$pci_addr"/driver/unbind 2>/dev/null || true
	# CRITICAL: use echo -n to clear driver_override, NOT echo ""
	echo -n >/sys/bus/pci/devices/"$pci_addr"/driver_override 2>/dev/null || true

	if [[ "$original_driver" == "nvidia" ]]; then
		modprobe nvidia 2>/dev/null || fmtr::warn "Failed to load NVIDIA driver"
	fi

	if [[ -e "/sys/bus/pci/drivers/${original_driver}/bind" ]]; then
		echo "$pci_addr" >/sys/bus/pci/drivers/"$original_driver"/bind 2>/dev/null &&
			fmtr::log "GPU bound to $original_driver" ||
			fmtr::error "Failed to bind GPU to $original_driver"
	else
		fmtr::warn "Driver $original_driver not available"
	fi

	local iommu_group
	iommu_group=$(get_iommu_group "$pci_addr")

	if [[ -n "$iommu_group" ]]; then
		while IFS= read -r dev; do
			[[ -n "$dev" ]] || continue
			[[ "$dev" == "$pci_addr" ]] && continue

			local dev_class
			dev_class=$(cat "/sys/bus/pci/devices/$dev/class" 2>/dev/null)
			dev_class=${dev_class#0x}

			if [[ "$dev_class" == "0604" ]]; then
				continue
			fi

			local dev_driver
			dev_driver=$(get_gpu_driver "$dev")

			if [[ -n "$dev_driver" ]]; then
				echo "$dev" >/sys/bus/pci/devices/"$dev"/driver/unbind 2>/dev/null || true
				echo -n >/sys/bus/pci/devices/"$dev"/driver_override 2>/dev/null || true
			fi
		done < <(get_iommu_group_devices "$iommu_group")
	fi

	fmtr::log "GPU $pci_addr is now available for host use"
}

gpu_mode_none() {
	local pci_addr="$1"

	fmtr::info "Unbinding GPU $pci_addr (power saving mode)..."

	echo "$pci_addr" >/sys/bus/pci/devices/"$pci_addr"/driver/unbind 2>/dev/null || true
	echo -n >/sys/bus/pci/devices/"$pci_addr"/driver_override 2>/dev/null || true

	local iommu_group
	iommu_group=$(get_iommu_group "$pci_addr")

	if [[ -n "$iommu_group" ]]; then
		while IFS= read -r dev; do
			[[ -n "$dev" ]] || continue
			[[ "$dev" == "$pci_addr" ]] && continue

			local dev_class
			dev_class=$(cat "/sys/bus/pci/devices/$dev/class" 2>/dev/null)
			dev_class=${dev_class#0x}

			if [[ "$dev_class" == "0604" ]]; then
				continue
			fi

			echo "$dev" >/sys/bus/pci/devices/"$dev"/driver/unbind 2>/dev/null || true
			echo -n >/sys/bus/pci/devices/"$dev"/driver_override 2>/dev/null || true
		done < <(get_iommu_group_devices "$iommu_group")
	fi

	fmtr::log "GPU $pci_addr is now unbound (power saving)"
}

show_current_status() {
	fmtr::info "Current GPU binding status..."

	local -a gpus
	while IFS='|' read -r bdf vendor device desc driver; do
		[[ -n "$bdf" ]] || continue
		gpus+=("$bdf|$vendor|$device|$desc|$driver")
	done < <(detect_gpus)

	printf '\n  %-15s %-40s %s\n' "PCI Address" "Description" "Current Driver"
	printf '  %s\n' "$(printf '%.0s-' {1..80})"

	for gpu in "${gpus[@]}"; do
		IFS='|' read -r bdf vendor device desc driver <<<"$gpu"
		printf '  %-15s %-40s %s\n' "$bdf" "${desc:0:40}" "${driver:-none}"
	done
}

main() {
	fmtr::box_text " GPU Binding Management "

	if [[ -z "$GPU_PCI_ADDR" ]]; then
		fmtr::warn "No GPU configured. Run VFIO setup first."
		read_config
	fi

	show_current_status

	echo ""
	fmtr::info "Available actions:"
	echo "  [1] Bind GPU to vfio-pci (VM mode)"
	echo "  [2] Bind GPU to original driver (Host mode)"
	echo "  [3] Unbind GPU (None/power saving)"
	echo "  [4] Configure persistent VFIO mode"
	echo "  [0] Back to main menu"

	local choice
	read -rp "$(fmtr::ask_inline 'Select action: ')" choice

	case $choice in
	1)
		if [[ -n "$GPU_PCI_ADDR" ]]; then
			gpu_mode_vm "$GPU_PCI_ADDR"
		else
			fmtr::error "No GPU configured"
		fi
		;;
	2)
		if [[ -n "$GPU_PCI_ADDR" ]]; then
			gpu_mode_host "$GPU_PCI_ADDR" "${GPU_DRIVER_ORIGINAL:-nvidia}"
		else
			fmtr::error "No GPU configured"
		fi
		;;
	3)
		if [[ -n "$GPU_PCI_ADDR" ]]; then
			gpu_mode_none "$GPU_PCI_ADDR"
		else
			fmtr::error "No GPU configured"
		fi
		;;
	4)
		fmtr::info "Persistent VFIO mode keeps GPU bound after reboot"
		fmtr::warn "This feature requires additional setup - coming soon"
		;;
	0)
		return
		;;
	*)
		fmtr::error "Invalid selection"
		;;
	esac
}

main
