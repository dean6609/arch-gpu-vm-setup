#!/usr/bin/env bash

# =============================================================================
# Module 01: BIOS Configuration Guide
# Provides instructions for BIOS settings required for GPU passthrough
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

print_amd_instructions() {
	fmtr::info "AMD CPU Configuration"
	echo ""
	echo "  1. Enter BIOS Setup (press Delete or F2 during boot)"
	echo "  2. Navigate to:"
	echo "     Advanced → CPU Configuration"
	echo "  3. Enable the following:"
	echo "     - SVM Mode (or AMD-V): ENABLED"
	echo "     - IOMMU: ENABLED"
	echo ""
	echo "  4. Navigate to:"
	echo "     Advanced → Display Configuration"
	echo "  5. Set Primary Display to: IGD (Integrated Graphics)"
	echo ""
	echo "  6. Connect your monitor to the MOTHERBOARD ports (not GPU)"
	echo ""
}

print_intel_instructions() {
	fmtr::info "Intel CPU Configuration"
	echo ""
	echo "  1. Enter BIOS Setup (press Delete or F2 during boot)"
	echo "  2. Navigate to:"
	echo "     Advanced → CPU Configuration"
	echo "  3. Enable the following:"
	echo "     - Intel Virtualization Technology (VT-x): ENABLED"
	echo "     - Intel VT for Directed I/O (VT-d): ENABLED"
	echo ""
	echo "  4. Navigate to:"
	echo "     Advanced → Display Configuration"
	echo "  5. Set Primary Display to: Internal Graphics / IGD"
	echo ""
	echo "  6. Connect your monitor to the MOTHERBOARD ports (not GPU)"
	echo ""
}

print_kernel_params_info() {
	fmtr::info "Required Kernel Parameters"
	echo ""
	echo "  The following kernel parameters are needed for GPU passthrough:"
	echo ""

	if [[ "$CPU_MANUFACTURER" == "AMD" ]]; then
		echo "  iommu=pt"
	else
		echo "  intel_iommu=on iommu=pt"
	fi

	echo "  vfio-pci.ids=XXXX:YYYY,XXXX:YYYY  (GPU vendor:device IDs)"
	echo ""
	echo "  These will be automatically configured by the VFIO module."
}

print_laptop_info() {
	fmtr::info "Laptop Configuration (MUX-less)"
	echo ""
	echo "  For laptops without a MUX switch:"
	echo ""
	echo "  - The dedicated GPU is always connected to the internal display"
	echo "  - Cannot switch between iGPU and dGPU without hardware switch"
	echo "  - For Looking Glass, you NEED an HDMI/DP dummy plug on the dGPU"
	echo ""
	echo "  Solution:"
	echo "  1. Install HDMI or DisplayPort dummy plug (~5 USD)"
	echo "  2. Connect dummy plug to the dedicated GPU"
	echo "  3. This allows the VM to output display even without laptop screen"
	echo ""
	echo "  Note: On MUX-less laptops, you may need kernel-zen with ACS patch"
	echo "  for proper IOMMU group isolation."
}

verify_bios_settings() {
	fmtr::info "Verifying BIOS settings from system..."

	local iommu_ok=0
	local virt_ok=0

	if [[ -d /sys/kernel/iommu_groups ]] &&
		[[ $(ls /sys/kernel/iommu_groups/ 2>/dev/null | wc -l) -gt 0 ]]; then
		local group_count
		group_count=$(ls /sys/kernel/iommu_groups/ 2>/dev/null | wc -l)
		fmtr::log "IOMMU: Active ($group_count groups found)"
		iommu_ok=1
	else
		fmtr::error "IOMMU: Not active - needs to be enabled in BIOS"
	fi

	if grep -q "iommu=pt\|iommu=on\|intel_iommu=on\|amd_iommu=on" /proc/cmdline 2>/dev/null; then
		fmtr::log "IOMMU kernel parameter: Configured in cmdline"
	fi

	if grep -qE 'svm|vmx' /proc/cpuinfo; then
		fmtr::log "CPU Virtualization: Supported"
		virt_ok=1
	else
		fmtr::error "CPU Virtualization: Not available"
	fi

	if ((iommu_ok && virt_ok)); then
		fmtr::log "System shows BIOS settings are applied correctly!"
		return 0
	else
		fmtr::warn "BIOS changes not detected - you may need to reboot"
		return 1
	fi
}

main() {
	fmtr::box_text " BIOS Configuration Guide "

	echo ""
	fmtr::info "IMPORTANT: These settings must be configured in your BIOS before proceeding."
	echo ""

	if [[ "$CPU_MANUFACTURER" == "AMD" ]]; then
		print_amd_instructions
	else
		print_intel_instructions
	fi

	print_kernel_params_info
	print_laptop_info

	echo ""
	fmtr::warn "After saving BIOS settings, reboot your system!"
	echo ""

	if prmt::yes_or_no "$(fmtr::ask 'Have you configured BIOS and rebooted?')"; then
		verify_bios_settings
	else
		fmtr::info "Please configure BIOS settings and reboot, then run this module again."
	fi
}

main
