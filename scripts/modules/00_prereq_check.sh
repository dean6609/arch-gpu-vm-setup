#!/usr/bin/env bash

# =============================================================================
# Module 00: Prerequisites Check
# Verifies all hardware and software requirements before installation
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

check_cpu_virtualization() {
	fmtr::info "Checking CPU virtualization support..."

	if grep -qE 'svm|vmx' /proc/cpuinfo; then
		local virt_type
		if grep -q 'svm' /proc/cpuinfo; then
			virt_type="AMD-V (SVM)"
		else
			virt_type="Intel VT-x (VMX)"
		fi
		fmtr::log "CPU Virtualization: $virt_type - DETECTED"
		return 0
	else
		fmtr::error "CPU Virtualization: NOT DETECTED"
		return 1
	fi
}

check_iommu() {
	fmtr::info "Checking IOMMU status..."

	# Check IOMMU groups via sysfs (does not require root/dmesg)
	if [[ -d /sys/kernel/iommu_groups ]]; then
		local group_count
		group_count=$(find /sys/kernel/iommu_groups -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
		if ((group_count > 0)); then
			fmtr::log "IOMMU: Active ($group_count groups found)"
		else
			fmtr::error "IOMMU: No groups found - enable IOMMU in BIOS"
			return 1
		fi
	else
		fmtr::error "IOMMU groups not accessible"
		return 1
	fi

	# Check kernel parameters via /proc/cmdline (does not require root)
	local cmdline
	cmdline=$(cat /proc/cmdline 2>/dev/null)
	local iommu_param_found=false

	if echo "$cmdline" | grep -qE 'iommu=pt|iommu=on|intel_iommu=on|amd_iommu=on'; then
		fmtr::log "IOMMU kernel parameter: configured (explicit)"
		iommu_param_found=true
	fi

	if echo "$cmdline" | grep -qE 'pcie_acs_override='; then
		fmtr::log "ACS override: configured ($(echo "$cmdline" | grep -oE 'pcie_acs_override=[^ ]*'))"
		iommu_param_found=true
	fi

	if echo "$cmdline" | grep -qE 'vfio-pci\.ids='; then
		fmtr::log "VFIO PCI IDs: configured in cmdline"
		iommu_param_found=true
	fi

	if [[ "$iommu_param_found" == false ]]; then
		# IOMMU groups exist (checked above) but no explicit cmdline param
		# On AMD this is normal - IOMMU auto-enables when SVM is on in BIOS
		if [[ "$CPU_VENDOR_ID" == "AuthenticAMD" ]] && ((group_count > 0)); then
			fmtr::log "IOMMU: auto-enabled by AMD (no explicit kernel param needed)"
		else
			fmtr::warn "No IOMMU kernel parameter found in /proc/cmdline"
			fmtr::info "Consider adding: iommu=pt (or intel_iommu=on for Intel)"
		fi
	fi

	# Check if linux-zen is running (has ACS patch)
	if uname -r | grep -q zen; then
		fmtr::log "Kernel: linux-zen detected (has ACS patch)"
	else
		fmtr::warn "Not running linux-zen kernel - ACS patch may not be available"
		fmtr::info "Current kernel: $(uname -r)"
	fi

	return 0
}

check_gpus() {
	fmtr::info "Detecting GPUs..."

	local -a gpus=()
	while IFS='|' read -r bdf vendor device desc driver; do
		[[ -n "$bdf" ]] && gpus+=("$bdf|$vendor|$device|$desc|$driver")
	done < <(detect_gpus)

	if ((${#gpus[@]} == 0)); then
		fmtr::error "No GPUs detected!"
		return 1
	fi

	fmtr::log "GPUs detected: ${#gpus[@]}"

	printf '\n  %-15s %-10s %-10s %-40s %s\n' "PCI Address" "Vendor" "Device" "Description" "Driver"
	printf '  %s\n' "$(printf '%.0s-' {1..100})"

	local dedicated=0
	for gpu in "${gpus[@]}"; do
		local bdf vendor device desc driver
		IFS='|' read -r bdf vendor device desc driver <<<"$gpu"

		local gpu_type
		gpu_type=$(get_gpu_type "$bdf")

		printf '  %-15s %-10s %-10s %-40s %s\n' \
			"$bdf" "$vendor" "$device" "${desc:0:40}" "${driver:-none}"

		if [[ "$gpu_type" == "dedicated" ]]; then
			((dedicated++))
		fi
	done

	if ((dedicated < 1)); then
		fmtr::warn "No dedicated GPU found - GPU passthrough requires 2 GPUs (1 integrated + 1 dedicated)"
		return 1
	fi

	return 0
}

check_kernel_modules() {
	fmtr::info "Checking kernel modules..."

	local -a required_modules=("vfio_pci" "vfio" "vfio_iommu_type1")
	local -a loaded_modules=()

	for mod in "${required_modules[@]}"; do
		if lsmod | grep -q "^$mod "; then
			fmtr::log "Module $mod: loaded"
			loaded_modules+=("$mod")
		else
			fmtr::warn "Module $mod: not loaded (will load after reboot)"
		fi
	done
}

check_distro() {
	fmtr::info "Checking distribution..."

	if [[ "$DISTRO" == "Arch" ]]; then
		fmtr::log "Distribution: $DISTRO - SUPPORTED"
		return 0
	else
		fmtr::warn "Distribution: $DISTRO - This script is optimized for Arch Linux"
		return 1
	fi
}

check_aur_helper() {
	fmtr::info "Checking AUR helper..."

	if command -v yay &>/dev/null || command -v paru &>/dev/null; then
		local aur_helper
		aur_helper=$(command -v yay || command -v paru)
		fmtr::log "AUR Helper: $aur_helper - FOUND"
		return 0
	else
		fmtr::warn "AUR Helper: Not found - needed for Looking Glass and some packages"
		fmtr::info "Install with: git clone https://aur.archlinux.org/yay.git /tmp/yay && cd /tmp/yay && makepkg -si"
		return 1
	fi
}

check_user_groups() {
	fmtr::info "Checking user groups..."

	local user_groups
	user_groups=$(id -nG "$USER")
	local -a required_groups=("kvm" "libvirt" "input")

	for grp in "${required_groups[@]}"; do
		if echo "$user_groups" | grep -qw "$grp"; then
			fmtr::log "Group $grp: OK"
		else
			fmtr::warn "Group $grp: Not a member (run: sudo usermod -aG $grp $USER)"
		fi
	done
}

check_ram() {
	fmtr::info "Checking RAM..."

	local total_kb available_kb
	total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
	available_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')

	local total_gb=$((total_kb / 1024 / 1024))
	local available_gb=$((available_kb / 1024 / 1024))

	printf '\n  Total RAM: %d GB\n' "$total_gb"
	printf '  Available: %d GB\n' "$available_gb"

	if ((total_gb < 16)); then
		fmtr::error "RAM: Less than 16GB - NOT RECOMMENDED for gaming VM"
		return 1
	elif ((total_gb < 32)); then
		fmtr::warn "RAM: 16-32GB - Gaming VM will have limited resources"
	else
		fmtr::log "RAM: Excellent for gaming VM"
	fi
}

check_disk_space() {
	fmtr::info "Checking disk space..."

	local images_dir="/var/lib/libvirt/images"
	local required_gb=100

	if [[ ! -d "$images_dir" ]]; then
		$ROOT_ESC mkdir -p "$images_dir" 2>/dev/null || true
	fi

	local available_kb
	available_kb=$(df "$images_dir" | tail -1 | awk '{print $4}')
	local available_gb=$((available_kb / 1024 / 1024))

	printf '\n  Available in %s: %d GB\n' "$images_dir" "$available_gb"

	if ((available_gb < required_gb)); then
		fmtr::error "Disk space: Less than ${required_gb}GB available - NOT ENOUGH"
		return 1
	else
		fmtr::log "Disk space: OK"
	fi
}

check_bootloader() {
	fmtr::info "Checking bootloader..."

	detect_bootloader
	if [[ -n "$BOOTLOADER_TYPE" ]]; then
		fmtr::log "Bootloader: $BOOTLOADER_TYPE - DETECTED"
		return 0
	else
		fmtr::error "Bootloader: Not detected"
		return 1
	fi
}

print_summary() {
	printf '\n\n'
	fmtr::box_text " Prerequisites Check Summary "
	printf '\n'

	local pass=0 fail=0

	check_cpu_virtualization && ((pass++)) || ((fail++))
	check_iommu && ((pass++)) || ((fail++))
	check_gpus && ((pass++)) || ((fail++))
	check_distro && ((pass++)) || ((fail++))
	check_aur_helper
	check_user_groups
	check_kernel_modules
	check_ram
	check_disk_space
	check_bootloader

	printf '\n  %bPassed: %d | Failed: %d%b\n\n' "$TEXT_BRIGHT_GREEN" "$pass" "$fail" "$RESET"

	if ((fail > 0)); then
		fmtr::warn "Some prerequisites are not met. Please address the issues above before continuing."
	else
		fmtr::log "All critical prerequisites are met! You can proceed with the installation."
	fi
}

print_summary
