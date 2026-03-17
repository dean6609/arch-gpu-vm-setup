#!/usr/bin/env bash

# =============================================================================
# Module 10: System Diagnostics
# Comprehensive diagnostic report for troubleshooting
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

print_system_info() {
	fmtr::info "System Information"
	echo ""

	local os_info
	os_info=$(grep -E '^NAME=|^VERSION=' /etc/os-release | head -2)
	echo "  OS: $os_info"

	local kernel
	kernel=$(uname -r)
	echo "  Kernel: $kernel"

	if [[ -f /etc/os-release ]]; then
		. /etc/os-release
		echo "  ID: $ID"
	fi

	detect_bootloader 2>/dev/null
	echo "  Bootloader: ${BOOTLOADER_TYPE:-unknown}"
}

print_cpu_info() {
	fmtr::info "CPU Information"
	echo ""

	local cpu_model
	cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
	echo "  Model: $cpu_model"

	local cpu_vendor
	cpu_vendor=$(grep vendor_id /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
	echo "  Vendor: $cpu_vendor"

	local cpu_cores
	cpu_cores=$(nproc)
	echo "  Cores: $cpu_cores"

	if grep -q 'svm' /proc/cpuinfo; then
		echo "  Virtualization: AMD-V (SVM) - DETECTED"
	elif grep -q 'vmx' /proc/cpuinfo; then
		echo "  Virtualization: Intel VT-x (VMX) - DETECTED"
	else
		echo "  Virtualization: NOT DETECTED"
	fi
}

print_memory_info() {
	fmtr::info "Memory Information"
	echo ""

	local total_kb available_kb
	total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
	available_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')

	local total_gb=$((total_kb / 1024 / 1024))
	local available_gb=$((available_kb / 1024 / 1024))

	echo "  Total: ${total_gb}GB"
	echo "  Available: ${available_gb}GB"
}

print_gpu_info() {
	fmtr::info "GPU Information"
	echo ""

	local -a gpus
	while IFS='|' read -r bdf vendor device desc driver; do
		[[ -n "$bdf" ]] || continue
		gpus+=("$bdf|$vendor|$device|$desc|$driver")
	done < <(detect_gpus)

	if ((${#gpus[@]} == 0)); then
		echo "  No GPUs detected"
		return
	fi

	for gpu in "${gpus[@]}"; do
		IFS='|' read -r bdf vendor device desc driver <<<"$gpu"

		local gpu_type
		gpu_type=$(get_gpu_type "$bdf")

		local iommu_group
		iommu_group=$(get_iommu_group "$bdf")

		echo "  GPU: $desc"
		echo "    PCI: $bdf"
		echo "    Vendor:Device: $vendor:$device"
		echo "    Type: $gpu_type"
		echo "    Driver: ${driver:-none}"
		echo "    IOMMU Group: ${iommu_group:-unknown}"
		echo ""
	done
}

print_iommu_groups() {
	fmtr::info "IOMMU Groups"
	echo ""

	if [[ ! -d /sys/kernel/iommu_groups ]]; then
		echo "  IOMMU groups not accessible"
		return
	fi

	local group_count
	group_count=$(ls -d /sys/kernel/iommu_groups/*/devices/ 2>/dev/null | wc -l)
	echo "  Total groups: $group_count"

	for group in /sys/kernel/iommu_groups/*/devices/*; do
		[[ -e "$group" ]] || continue

		local group_num
		group_num=$(basename "$(dirname "$group")")

		local device
		device=$(basename "$group")

		local vendor device_desc
		vendor=$(cat "/sys/bus/pci/devices/$device/vendor" 2>/dev/null | tr -d ' ')
		device_desc=$(lspci -D -s "$device" 2>/dev/null | sed 's/.* //')

		if [[ "$vendor" == "0x10de" || "$vendor" == "0x1002" || "$vendor" == "0x8086" ]]; then
			echo "  Group $group_num: $device ($vendor:$device_desc)"
		fi
	done
}

print_vfio_status() {
	fmtr::info "VFIO Status"
	echo ""

	if lsmod | grep -q "^vfio_pci "; then
		echo "  vfio_pci: LOADED"
	else
		echo "  vfio_pci: NOT LOADED"
	fi

	if lsmod | grep -q "^vfio "; then
		echo "  vfio: LOADED"
	else
		echo "  vfio: NOT LOADED"
	fi

	if lsmod | grep -q "^vfio_iommu_type1 "; then
		echo "  vfio_iommu_type1: LOADED"
	else
		echo "  vfio_iommu_type1: NOT LOADED"
	fi

	echo ""
	echo "  VFIO bound devices:"
	for dev in /sys/bus/pci/drivers/vfio-pci/*; do
		[[ -d "$dev" ]] || continue
		local bdf
		bdf=$(basename "$dev")
		local desc
		desc=$(lspci -D -s "$bdf" 2>/dev/null | sed 's/.* //')
		echo "    $bdf: $desc"
	done

	if [[ -f /etc/modprobe.d/vfio.conf ]]; then
		echo ""
		echo "  VFIO Config (/etc/modprobe.d/vfio.conf):"
		sed 's/^/    /' /etc/modprobe.d/vfio.conf
	fi
}

print_kernel_params() {
	fmtr::info "Kernel Parameters"
	echo ""

	local cmdline
	cmdline=$(cat /proc/cmdline)

	echo "  Command line:"
	echo "    $cmdline"
	echo ""

	if echo "$cmdline" | grep -q 'intel_iommu=on'; then
		echo "  intel_iommu: ON"
	elif echo "$cmdline" | grep -q 'iommu='; then
		echo "  iommu: CONFIGURED"
	else
		echo "  iommu: NOT CONFIGURED"
	fi

	if echo "$cmdline" | grep -q 'vfio-pci.ids'; then
		echo "  vfio-pci.ids: CONFIGURED"
	else
		echo "  vfio-pci.ids: NOT CONFIGURED"
	fi
}

print_libvirt_status() {
	fmtr::info "Libvirt Status"
	echo ""

	if systemctl is-active libvirtd &>/dev/null; then
		echo "  libvirtd: ACTIVE"
	else
		echo "  libvirtd: INACTIVE"
	fi

	if systemctl is-active virtlogd &>/dev/null; then
		echo "  virtlogd: ACTIVE"
	else
		echo "  virtlogd: INACTIVE"
	fi

	echo ""
	echo "  VMs:"
	virsh list --all 2>/dev/null | sed 's/^/    /'

	echo ""
	echo "  Networks:"
	virsh net-list 2>/dev/null | sed 's/^/    /'
}

print_looking_glass_status() {
	fmtr::info "Looking Glass Status"
	echo ""

	if command -v looking-glass &>/dev/null; then
		echo "  Client: INSTALLED"
	else
		echo "  Client: NOT INSTALLED"
	fi

	if lsmod | grep -q "^kvmfr "; then
		echo "  KVMFR module: LOADED"
	else
		echo "  KVMFR module: NOT LOADED"
	fi

	if [[ -c "/dev/kvmfr0" ]]; then
		echo "  KVMFR device: /dev/kvmfr0 EXISTS"
	elif [[ -c "/dev/shm/looking-glass" ]]; then
		echo "  IVSHMEM device: /dev/shm/looking-glass EXISTS"
	else
		echo "  Shared memory device: NOT FOUND"
	fi

	if [[ -f /etc/modprobe.d/kvmfr.conf ]]; then
		echo "  KVMFR config:"
		sed 's/^/    /' /etc/modprobe.d/kvmfr.conf
	fi
}

print_user_groups() {
	fmtr::info "User Groups"
	echo ""

	echo "  Groups for $USER:"
	echo "    $(id -nG "$USER")"

	local -a required_groups=("kvm" "libvirt" "input")
	local missing=0

	for grp in "${required_groups[@]}"; do
		if ! id -nG "$USER" | grep -qw "$grp"; then
			echo "    [!] Missing: $grp"
			((missing++))
		fi
	done

	if ((missing > 0)); then
		echo ""
		fmtr::warn "User is missing required groups. Run:"
		echo "    sudo usermod -aG kvm,libvirt,input $USER"
	fi
}

generate_full_report() {
	fmtr::box_text " GPU Passthrough Diagnostics "
	echo ""
	echo "Generated: $(date)"
	echo ""

	print_system_info
	echo ""
	print_cpu_info
	echo ""
	print_memory_info
	echo ""
	print_gpu_info
	echo ""
	print_iommu_groups
	echo ""
	print_vfio_status
	echo ""
	print_kernel_params
	echo ""
	print_libvirt_status
	echo ""
	print_looking_glass_status
	echo ""
	print_user_groups

	echo ""
	fmtr::info "Diagnostics complete!"
}

main() {
	generate_full_report

	echo ""
	if prmt::yes_or_no "$(fmtr::ask 'Save diagnostics to file?')"; then
		local log_file="/tmp/gpu-vm-diagnostics-$(date +%Y%m%d_%H%M%S).txt"
		generate_full_report >"$log_file"
		fmtr::log "Saved to: $log_file"
	fi
}

main
