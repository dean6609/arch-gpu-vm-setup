#!/usr/bin/env bash

# =============================================================================
# Module 03: VFIO / GPU Passthrough Configuration
# Configures VFIO, IOMMU, kernel parameters, and bootloader
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

readonly VFIO_CONF_PATH="/etc/modprobe.d/vfio.conf"
readonly BLACKLIST_CONF_PATH="/etc/modprobe.d/blacklist-gpu-passthrough.conf"
readonly VFIO_KERNEL_OPTS_REGEX='(intel_iommu=[^ ]*|iommu=[^ ]*|vfio-pci\.ids=[^ ]*)'
readonly LIMINE_ENTRY_REGEX='^KERNEL_CMDLINE\[.*\]\+?='

declare -A GPU_DRIVERS=(
	["0x10de"]="nouveau nvidia nvidia_drm nvidia_modeset nvidia_uvm"
	["0x1002"]="amdgpu radeon"
	["0x8086"]="i915 xe"
)

VFIO_PCI_IDS=""
BOOTLOADER_CHANGED=0

revert_vfio_config() {
	fmtr::info "Reverting VFIO configuration..."

	if [[ -f "$VFIO_CONF_PATH" ]]; then
		$ROOT_ESC rm -v "$VFIO_CONF_PATH" &>>"$LOG_FILE"
		fmtr::log "Removed VFIO config"
	fi

	if [[ -f "$BLACKLIST_CONF_PATH" ]]; then
		$ROOT_ESC rm -v "$BLACKLIST_CONF_PATH" &>>"$LOG_FILE"
		fmtr::log "Removed GPU blacklist config"
	fi

	detect_bootloader || return 1

	case $BOOTLOADER_TYPE in
	grub)
		$ROOT_ESC sed -E -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/{
                s/'"$VFIO_KERNEL_OPTS_REGEX"'//g
                s/[[:space:]]+/ /g
                s/"[[:space:]]+/"
                s/[[:space:]]+"/"/
            }' "$BOOTLOADER_CONFIG"
		;;
	systemd-boot)
		for entry in /boot/loader/entries/*.conf; do
			[[ -f "$entry" ]] || continue
			$ROOT_ESC sed -E -i "/^options / {
                    s/$VFIO_KERNEL_OPTS_REGEX//g;
                    s/[[:space:]]+/ /g;
                    s/[[:space:]]+$//;
                }" "$entry"
		done
		;;
	limine)
		$ROOT_ESC sed -E -i "/${LIMINE_ENTRY_REGEX}/ {
                s/$VFIO_KERNEL_OPTS_REGEX//g;
                s/[[:space:]]+/ /g;
            }" "$BOOTLOADER_CONFIG"
		;;
	esac

	fmtr::log "Reverted bootloader kernel parameters"
}

select_gpu() {
	local -a gpus=()
	local -A lspci_map=()

	while IFS= read -r line; do
		lspci_map["${line%% *}"]="$line"
	done < <(lspci -D 2>/dev/null)

	for dev in /sys/bus/pci/devices/*; do
		read -r dev_class <"$dev/class" 2>/dev/null || continue
		[[ $dev_class == 0x03* ]] || continue

		local bdf=${dev##*/}
		local desc=${lspci_map[$bdf]:-}
		[[ -n "$desc" ]] || continue
		desc=${desc##*[}
		desc=${desc%%]*}

		local vendor_id device_id
		vendor_id=$(cat "$dev/vendor" 2>/dev/null)
		device_id=$(cat "$dev/device" 2>/dev/null)

		local driver=""
		if [[ -L "$dev/driver" ]]; then
			driver=$(basename "$(readlink "$dev/driver")")
		fi

		gpus+=("$bdf|$vendor_id|$device_id|$desc|$driver")
	done

	((${#gpus[@]})) || {
		fmtr::error "No GPUs detected!"
		return 1
	}
	((${#gpus[@]} == 1)) && fmtr::warn "Only one GPU detected! Passing it through will leave host without display."

	echo ""
	fmtr::info "Available GPUs:"
	printf '\n  %-3s %-15s %-10s %-10s %-40s %s\n' "#" "PCI Address" "Vendor" "Device" "Description" "Driver"
	printf '  %s\n' "$(printf '%.0s-' {1..110})"

	for ((i = 0; i < ${#gpus[@]}; i++)); do
		IFS='|' read -r bdf vendor device desc driver <<<"${gpus[i]}"
		printf '  %-3d %-15s %-10s %-10s %-40s %s\n' \
			$((i + 1)) "$bdf" "$vendor" "$device" "${desc:0:40}" "${driver:-none}"
	done

	local selection
	while :; do
		read -rp "$(fmtr::ask_inline 'Select GPU for passthrough: ')" selection
		((selection >= 1 && selection <= ${#gpus[@]})) 2>/dev/null && break
		fmtr::error "Invalid selection"
	done

	local selected_gpu="${gpus[$((selection - 1))]}"
	IFS='|' read -r GPU_PCI_ADDR GPU_VENDOR_ID GPU_DEVICE_ID GPU_NAME GPU_DRIVER_ORIGINAL <<<"$selected_gpu"

	export GPU_PCI_ADDR GPU_VENDOR_ID GPU_DEVICE_ID GPU_NAME GPU_DRIVER_ORIGINAL
}

configure_iommu() {
	fmtr::info "Configuring IOMMU and VFIO for $GPU_PCI_ADDR..."

	local iommu_group
	iommu_group=$(readlink -f /sys/bus/pci/devices/${GPU_PCI_ADDR}/iommu_group | xargs basename)

	if [[ -z "$iommu_group" ]]; then
		fmtr::error "Could not determine IOMMU group for $GPU_PCI_ADDR"
		return 1
	fi

	fmtr::log "IOMMU Group: $iommu_group"

	local -a group_devices=()
	for dev in /sys/kernel/iommu_groups/${iommu_group}/devices/*; do
		[[ -e "$dev" ]] || continue
		group_devices+=("$(basename "$dev")")
	done

	fmtr::log "Devices in IOMMU group $iommu_group: ${#group_devices[@]}"

	local -a iommu_ids=()
	local -a all_group_devices=()

	for dev in "${group_devices[@]}"; do
		all_group_devices+=("$dev")

		local vendor device dev_class
		vendor=$(cat "/sys/bus/pci/devices/$dev/vendor" 2>/dev/null)
		device=$(cat "/sys/bus/pci/devices/$dev/device" 2>/dev/null)
		dev_class=$(cat "/sys/bus/pci/devices/$dev/class" 2>/dev/null)
		dev_class=${dev_class#0x}

		local dev_desc
		dev_desc=$(lspci -D -s "$dev" 2>/dev/null | sed 's/.* //')

		if [[ -n "$vendor" && -n "$device" ]]; then
			local ids="${vendor#0x}:${device#0x}"
			iommu_ids+=("$ids")
			fmtr::log "  Found device: $dev ($dev_desc) - $ids"
		fi
	done

	local gpu_slot="${GPU_PCI_ADDR%.*}"
	for dev in /sys/bus/pci/devices/${gpu_slot}.*; do
		[[ -e "$dev" ]] || continue
		local bdf
		bdf=$(basename "$dev")
		local already_found=0
		for existing in "${group_devices[@]}"; do
			[[ "$bdf" == "$existing" ]] && {
				already_found=1
				break
			}
		done
		((already_found)) && continue
		local vendor device
		vendor=$(cat "$dev/vendor" 2>/dev/null)
		device=$(cat "$dev/device" 2>/dev/null)
		if [[ -n "$vendor" && -n "$device" ]]; then
			local ids="${vendor#0x}:${device#0x}"
			iommu_ids+=("$ids")
			group_devices+=("$bdf")
			fmtr::log "  Found sibling device: $bdf (same slot, ACS-separated) - $ids"
		fi
	done

	local bad_device_class="0604"
	local bad_devices=()
	for dev in "${all_group_devices[@]}"; do
		local dev_class
		dev_class=$(cat "/sys/bus/pci/devices/$dev/class" 2>/dev/null)
		dev_class=${dev_class#0x}

		if [[ "$dev_class" == "$bad_device_class" ]]; then
			fmtr::warn "Excluding PCI bridge from passthrough: $dev"
			bad_devices+=("$dev")
		fi
	done

	if ((${#bad_devices[@]} > 0)); then
		local filtered_ids=()
		for id in "${iommu_ids[@]}"; do
			local skip=0
			for bad in "${bad_devices[@]}"; do
				local bad_vendor bad_device
				bad_vendor=$(cat "/sys/bus/pci/devices/$bad/vendor" 2>/dev/null | tr -d ' ')
				bad_device=$(cat "/sys/bus/pci/devices/$bad/device" 2>/dev/null | tr -d ' ')
				local bad_id="${bad_vendor#0x}:${bad_device#0x}"
				if [[ "$id" == "$bad_id" ]]; then
					skip=1
					break
				fi
			done
			((skip)) && continue
			filtered_ids+=("$id")
		done
		iommu_ids=("${filtered_ids[@]}")
	fi

	VFIO_PCI_IDS=$(
		IFS=,
		echo "${iommu_ids[*]}"
	)
	GPU_IOMMU_GROUP="$iommu_group"

	if ((${#iommu_ids[@]} == 0)); then
		fmtr::error "No devices to passthrough in IOMMU group"
		return 1
	fi

	fmtr::log "VFIO PCI IDs: $VFIO_PCI_IDS"

	create_backup
}

write_vfio_config() {
	fmtr::info "Writing VFIO configuration..."

	local target_vendor=${GPU_VENDOR_ID#0x}

	{
		printf '# VFIO GPU Passthrough Configuration\n'
		printf '# Generated: %s\n\n' "$(date)"
		printf 'options vfio-pci ids=%s disable_vga=1\n' "$VFIO_PCI_IDS"

		for soft in ${GPU_DRIVERS["0x${target_vendor}"]:-}; do
			printf 'softdep %s pre: vfio-pci\n' "$soft"
		done
	} | $ROOT_ESC tee "$VFIO_CONF_PATH" >/dev/null

	fmtr::log "Written: $VFIO_CONF_PATH"

	case "$target_vendor" in
	10de)
		{
			printf '# GPU Passthrough - Driver Blacklist\n'
			printf '# Prevents NVIDIA driver from loading at boot\n\n'
			printf 'install nvidia /bin/false\n'
			printf 'install nvidia_drm /bin/false\n'
			printf 'install nvidia_modeset /bin/false\n'
			printf 'install nvidia_uvm /bin/false\n'
		} | $ROOT_ESC tee "$BLACKLIST_CONF_PATH" >/dev/null
		fmtr::log "Written: $BLACKLIST_CONF_PATH (NVIDIA blacklist)"
		;;
	*)
		fmtr::log "Skipping blacklist file (softdep in vfio.conf is sufficient for non-NVIDIA)"
		;;
	esac

	GPU_AUDIO_PCI=""
	GPU_AUDIO_IDS=""

	local iommu_group
	iommu_group=$(readlink -f /sys/bus/pci/devices/${GPU_PCI_ADDR}/iommu_group | xargs basename)

	for dev in /sys/kernel/iommu_groups/${iommu_group}/devices/*; do
		[[ -e "$dev" ]] || continue
		local bdf
		bdf=$(basename "$dev")

		[[ "$bdf" == "$GPU_PCI_ADDR" ]] && continue

		local class vendor
		class=$(cat "$dev/class" 2>/dev/null)
		vendor=$(cat "$dev/vendor" 2>/dev/null)

		if [[ "$class" == "0x0403" ]]; then
			GPU_AUDIO_PCI="$bdf"
			GPU_AUDIO_IDS="${vendor#0x}:$(cat "$dev/device" 2>/dev/null | tr -d ' ')"
			fmtr::log "Found audio device in IOMMU group: $bdf"
		fi
	done

	export GPU_AUDIO_PCI GPU_AUDIO_IDS
	write_config
}

configure_mkinitcpio() {
	fmtr::info "Configuring mkinitcpio..."

	local mkinitcpio_conf="/etc/mkinitcpio.conf"

	if ! grep -q "^MODULES=(.*vfio" "$mkinitcpio_conf" 2>/dev/null; then
		$ROOT_ESC sed -i 's/^MODULES=()/MODULES=(vfio vfio_iommu_type1 vfio_pci)/' "$mkinitcpio_conf"
		fmtr::log "Added VFIO modules to mkinitcpio.conf"
	else
		fmtr::log "VFIO modules already in mkinitcpio.conf"
	fi
}

configure_bootloader_kernel_params() {
	fmtr::info "Configuring bootloader kernel parameters..."

	detect_bootloader || return 1

	local -a kernel_opts
	kernel_opts=("iommu=pt" "vfio-pci.ids=${VFIO_PCI_IDS}")

	if [[ "$CPU_VENDOR_ID" == "GenuineIntel" ]]; then
		kernel_opts=("intel_iommu=on" "${kernel_opts[@]}")
	fi

	local kernel_opts_str="${kernel_opts[*]}"

	case $BOOTLOADER_TYPE in
	grub)
		if ! grep -Eq "^GRUB_CMDLINE_LINUX_DEFAULT=.*vfio-pci.ids" "$BOOTLOADER_CONFIG"; then
			$ROOT_ESC sed -E -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/ {
                    s/^GRUB_CMDLINE_LINUX_DEFAULT=//;
                    s/^\"//; s/\"$//;
                    s/$VFIO_KERNEL_OPTS_REGEX//g;
                    s/[[:space:]]+/ /g;
                    s/[[:space:]]+$//;
                    s|^|GRUB_CMDLINE_LINUX_DEFAULT=\"|;
                    s|$| ${kernel_opts_str}\"|;
                }" "$BOOTLOADER_CONFIG"

			BOOTLOADER_CHANGED=1
			fmtr::log "Added kernel params to GRUB"
		else
			fmtr::log "Kernel params already in GRUB config"
		fi
		;;
	systemd-boot)
		for entry in /boot/loader/entries/*.conf; do
			[[ -f "$entry" ]] || continue

			if ! grep -q "vfio-pci.ids" "$entry"; then
				$ROOT_ESC sed -E -i "/^options / s/$/ ${kernel_opts_str}/" "$entry"
				BOOTLOADER_CHANGED=1
			fi
		done
		fmtr::log "Added kernel params to systemd-boot entries"
		;;
	limine)
		if ! grep -E "${LIMINE_ENTRY_REGEX}" "$BOOTLOADER_CONFIG" | grep -q "vfio-pci.ids"; then
			$ROOT_ESC sed -E -i "/${LIMINE_ENTRY_REGEX}/ s/\"$/ ${kernel_opts_str}\"/" "$BOOTLOADER_CONFIG"
			BOOTLOADER_CHANGED=1
			fmtr::log "Added kernel params to Limine"
		else
			fmtr::log "Kernel params already in Limine config"
		fi
		;;
	esac
}

rebuild_bootloader() {
	case $BOOTLOADER_TYPE in
	grub)
		if ((BOOTLOADER_CHANGED)); then
			fmtr::info "Rebuilding GRUB configuration..."
			$ROOT_ESC grub-mkconfig -o /boot/grub/grub.cfg &>>"$LOG_FILE" &&
				fmtr::log "GRUB config rebuilt" ||
				fmtr::error "Failed to rebuild GRUB"
		fi
		;;
	limine)
		if ((BOOTLOADER_CHANGED)) && command -v limine-mkinitcpio &>/dev/null; then
			fmtr::info "Rebuilding Limine configuration..."
			$ROOT_ESC limine-mkinitcpio &>>"$LOG_FILE" &&
				fmtr::log "Limine config rebuilt" ||
				fmtr::error "Failed to rebuild Limine config"
		fi
		;;
	esac
}

rebuild_initramfs() {
	fmtr::info "Rebuilding initramfs..."
	$ROOT_ESC mkinitcpio -P &>>"$LOG_FILE" &&
		fmtr::log "Initramfs rebuilt" ||
		fmtr::error "Failed to rebuild initramfs"
}

main() {
	fmtr::box_text " VFIO / GPU Passthrough Configuration "

	if prmt::yes_or_no "$(fmtr::ask 'Remove existing VFIO configuration?')"; then
		revert_vfio_config
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Configure GPU passthrough now?')"; then
		select_gpu || exit 1
		configure_iommu || exit 1
		write_vfio_config
		configure_mkinitcpio
		configure_bootloader_kernel_params
		rebuild_bootloader
		rebuild_initramfs

		fmtr::warn "REBOOT REQUIRED for GPU passthrough to take effect!"
		fmtr::info "After reboot, run this module again to verify configuration."
	fi
}

main
