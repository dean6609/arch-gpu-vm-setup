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

HELPER="${SCRIPT_DIR}/gaming-mode-helper.sh"

gpu_mode_vm() {
	local pci_addr="$1"

	fmtr::info "Binding GPU $pci_addr to vfio-pci (VM mode)..."

	# Load vfio modules if not already loaded
	if ! lsmod | grep -q vfio_pci; then
		fmtr::info "Loading vfio-pci modules..."
		sudo modprobe vfio-pci 2>/dev/null || true
		sudo modprobe vfio 2>/dev/null || true
		sudo modprobe vfio_iommu_type1 2>/dev/null || true
	fi

	local current_driver
	current_driver=$(get_gpu_driver "$pci_addr")

	if [[ "$current_driver" == "nvidia" ]]; then
		fmtr::info "Unloading NVIDIA modules..."
		rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true
	fi

	if [[ -e "/sys/bus/pci/devices/$pci_addr/driver" ]]; then
		sudo "$HELPER" unbind_device "$pci_addr"
	fi

	echo "vfio-pci" | sudo tee "/sys/bus/pci/devices/$pci_addr/driver_override" >/dev/null 2>&1
	echo "$pci_addr" | sudo tee "/sys/bus/pci/drivers/vfio-pci/bind" >/dev/null 2>&1 &&
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
				sudo "$HELPER" unbind_device "$dev"
			fi

			echo "vfio-pci" | sudo tee "/sys/bus/pci/devices/$dev/driver_override" >/dev/null 2>&1 || true
			echo "$dev" | sudo tee "/sys/bus/pci/drivers/vfio-pci/bind" >/dev/null 2>&1 || true
			fmtr::log "Bound companion device: $dev"
		done < <(get_iommu_group_devices "$iommu_group")
	fi

	fmtr::log "GPU $pci_addr is now bound to vfio-pci for VM passthrough"
}

gpu_mode_host() {
	local pci_addr="$1"
	local original_driver="${2:-nvidia}"

	fmtr::info "Binding GPU $pci_addr to $original_driver (host mode)..."

	sudo "$HELPER" unbind_device "$pci_addr"
	sudo "$HELPER" clear_override "$pci_addr"

	if [[ "$original_driver" == "nvidia" ]]; then
		sudo modprobe nvidia 2>/dev/null || fmtr::warn "Failed to load NVIDIA driver"
	fi

	if [[ -e "/sys/bus/pci/drivers/${original_driver}/bind" ]]; then
		echo "$pci_addr" | sudo tee "/sys/bus/pci/drivers/${original_driver}/bind" >/dev/null 2>&1 &&
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
				sudo "$HELPER" unbind_device "$dev"
				sudo "$HELPER" clear_override "$dev"
			fi
		done < <(get_iommu_group_devices "$iommu_group")
	fi

	fmtr::log "GPU $pci_addr is now available for host use"
}

gpu_mode_none() {
	local pci_addr="$1"

	fmtr::info "Unbinding GPU $pci_addr (power saving mode)..."

	sudo "$HELPER" unbind_device "$pci_addr"
	sudo "$HELPER" clear_override "$pci_addr"

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

			sudo "$HELPER" unbind_device "$dev"
			sudo "$HELPER" clear_override "$dev"
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

	# Detect all GPUs
	local -a gpus=()
	while IFS='|' read -r bdf vendor device desc driver; do
		[[ -n "$bdf" ]] || continue
		gpus+=("$bdf|$vendor|$device|$desc|$driver")
	done < <(detect_gpus)

	if [[ ${#gpus[@]} -eq 0 ]]; then
		fmtr::error "No GPUs detected!"
		return 1
	fi

	show_current_status

	# GPU selection
	local target_gpu target_driver
	if [[ ${#gpus[@]} -eq 1 ]]; then
		IFS='|' read -r target_gpu _ _ _ target_driver <<<"${gpus[0]}"
		fmtr::info "Using GPU: $target_gpu"
	else
		echo ""
		fmtr::info "Select GPU to operate on:"
		for ((i = 0; i < ${#gpus[@]}; i++)); do
			IFS='|' read -r bdf _ _ desc driver <<<"${gpus[i]}"
			printf '  [%d] %s (%s) - %s\n' "$((i + 1))" "$bdf" "$desc" "${driver:-none}"
		done
		local gpu_sel
		read -rp "$(fmtr::ask_inline 'GPU [1-9]: ')" gpu_sel
		if [[ "$gpu_sel" =~ ^[0-9]+$ ]] && ((gpu_sel >= 1 && gpu_sel <= ${#gpus[@]})); then
			IFS='|' read -r target_gpu _ _ _ target_driver <<<"${gpus[$((gpu_sel - 1))]}"
		else
			fmtr::error "Invalid selection"
			return 1
		fi
	fi

	echo ""
	fmtr::info "Operating on: $target_gpu (current: ${target_driver:-none})"
	echo ""
	fmtr::info "Available actions:"
	echo "  [1] Bind GPU to vfio-pci (VM mode)"
	echo "  [2] Bind GPU to original driver (Host mode)"
	echo "  [3] Unbind GPU (None/power saving)"
	echo "  [0] Back to main menu"

	local choice
	read -rp "$(fmtr::ask_inline 'Select action: ')" choice

	case $choice in
	1)
		gpu_mode_vm "$target_gpu"
		;;
	2)
		local driver="${GPU_DRIVER_ORIGINAL:-amdgpu}"
		# If target is not the configured dGPU, use its own driver
		if [[ "$target_gpu" != "$GPU_PCI_ADDR" && -n "$target_driver" && "$target_driver" != "vfio-pci" ]]; then
			driver="$target_driver"
		fi
		gpu_mode_host "$target_gpu" "$driver"
		;;
	3)
		gpu_mode_none "$target_gpu"
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
