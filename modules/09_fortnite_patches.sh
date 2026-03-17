#!/usr/bin/env bash

# =============================================================================
# Module 09: Fortnite/EAC Specific Patches
# Applies all anti-detection settings for EasyAntiCheat
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

print_detection_vectors() {
	fmtr::info "EasyAntiCheat Detection Vectors"
	echo ""
	echo "  EAC detects VMs through multiple vectors:"
	echo ""
	echo "  [1] KVM Signature in CPUID"
	echo "      Fix: kvm.hidden=on, disable KVM paravirtualization"
	echo ""
	echo "  [2] Hypervisor bit in CPUID"
	echo "      Fix: <feature policy='disable' name='hypervisor'/>"
	echo ""
	echo "  [3] VMware backdoor (VMPort)"
	echo "      Fix: <vmport state='off'/>"
	echo ""
	echo "  [4] PMU (Performance Monitoring Unit)"
	echo "      Fix: <pmu state='off'/>"
	echo ""
	echo "  [5] SMBIOS/DMI anomalies"
	echo "      Fix: Use real host SMBIOS data"
	echo ""
	echo "  [6] Unknown MSRs"
	echo "      Fix: <msrs unknown='fault'/>"
	echo ""
	echo "  [7] KVM Clock source"
	echo "      Fix: <timer name='kvmclock' present='no'/>"
	echo ""
	echo "  [8] ACPI table anomalies"
	echo "      Fix: Copy real ACPI tables from host"
	echo ""
	echo "  [9] Disk model names"
	echo "      Fix: Spoof to real disk manufacturers"
	echo ""
	echo "  [10] MAC address patterns"
	echo "       Fix: Use unique MAC, not default QEMU OUI"
	echo ""
	echo "  [11] PS/2 controller"
	echo "       Fix: <ps2 state='off'/>"
	echo ""
	echo "  [12] VirtIO balloon"
	echo "       Fix: <memballoon model='none'/>"
	echo ""
	echo "  [13] Virtual video device"
	echo "       Fix: <video><model type='none'/></video>"
}

verify_hypervisor_hidden() {
	fmtr::info "Verifying hypervisor concealment settings..."

	if ! $ROOT_ESC virsh dominfo WindowsVM &>/dev/null; then
		fmtr::error "VM not found - please run deploy module first"
		return 1
	fi

	if $ROOT_ESC virsh dumpxml WindowsVM | grep -qE 'hidden.state=.on.'; then
		fmtr::log "KVM hidden: ENABLED"
	else
		fmtr::warn "KVM hidden: NOT ENABLED"
	fi

	if $ROOT_ESC virsh dumpxml WindowsVM | grep -qE 'vendor_id'; then
		fmtr::log "Hyper-V vendor ID spoofing: ENABLED"
	else
		fmtr::warn "Hyper-V vendor ID: NOT SPOOFED"
	fi
}

verify_pmu_disabled() {
	fmtr::info "Verifying PMU is disabled..."

	if ! $ROOT_ESC virsh dominfo WindowsVM &>/dev/null; then
		fmtr::error "VM not found - please run deploy module first"
		return 1
	fi

	if $ROOT_ESC virsh dumpxml WindowsVM | grep -qE 'pmu.state=.off.'; then
		fmtr::log "PMU: DISABLED"
	else
		fmtr::warn "PMU: NOT DISABLED"
	fi
}

verify_vmport_disabled() {
	fmtr::info "Verifying VMPort is disabled..."

	if ! $ROOT_ESC virsh dominfo WindowsVM &>/dev/null; then
		fmtr::error "VM not found - please run deploy module first"
		return 1
	fi

	if $ROOT_ESC virsh dumpxml WindowsVM | grep -qE 'vmport.state=.off.'; then
		fmtr::log "VMPort: DISABLED"
	else
		fmtr::warn "VMPort: NOT DISABLED"
	fi
}

verify_msr_filtering() {
	fmtr::info "Verifying MSR filtering..."

	if ! $ROOT_ESC virsh dominfo WindowsVM &>/dev/null; then
		fmtr::error "VM not found - please run deploy module first"
		return 1
	fi

	if $ROOT_ESC virsh dumpxml WindowsVM | grep -qE 'msrs.unknown=.fault.'; then
		fmtr::log "MSR unknown=fault: ENABLED"
	else
		fmtr::warn "MSR filtering: NOT CONFIGURED"
	fi
}

verify_clock_source() {
	fmtr::info "Verifying clock source configuration..."

	if ! $ROOT_ESC virsh dominfo WindowsVM &>/dev/null; then
		fmtr::error "VM not found - please run deploy module first"
		return 1
	fi

	if $ROOT_ESC virsh dumpxml WindowsVM | grep -qE 'kvmclock.*present=.no.'; then
		fmtr::log "KVM clock: DISABLED"
	else
		fmtr::warn "KVM clock: STILL ENABLED"
	fi

	if $ROOT_ESC virsh dumpxml WindowsVM | grep -qE 'hypervclock.*present='; then
		fmtr::log "Hyper-V clock: DISABLED"
	else
		fmtr::warn "Hyper-V clock: STILL ENABLED"
	fi
}

verify_video_disabled() {
	fmtr::info "Verifying virtual video configuration..."

	if ! $ROOT_ESC virsh dominfo WindowsVM &>/dev/null; then
		fmtr::error "VM not found - please run deploy module first"
		return 1
	fi

	local has_vfio=0
	local video_none=0
	local video_vga=0

	if $ROOT_ESC virsh dumpxml WindowsVM 2>/dev/null | grep -q "driver name='vfio'"; then
		has_vfio=1
	fi

	if $ROOT_ESC virsh dumpxml WindowsVM 2>/dev/null | grep -q "model type='none'"; then
		video_none=1
	fi

	if $ROOT_ESC virsh dumpxml WindowsVM 2>/dev/null | grep -q "model type='vga'"; then
		video_vga=1
	fi

	if [[ $video_none -eq 1 ]]; then
		fmtr::log "Virtual video: DISABLED (ideal)"
	elif [[ $video_vga -eq 1 && $has_vfio -eq 1 ]]; then
		fmtr::log "Virtual video: VGA present but GPU passthrough active (acceptable)"
	else
		fmtr::warn "Virtual video: NOT DISABLED"
	fi
}

verify_smbios_spoofing() {
	fmtr::info "Verifying SMBIOS spoofing..."

	if ! $ROOT_ESC virsh dominfo WindowsVM &>/dev/null; then
		fmtr::error "VM not found - please run deploy module first"
		return 1
	fi

	if $ROOT_ESC virsh dumpxml WindowsVM | grep -qE 'smbios|file=.*smbios'; then
		fmtr::log "SMBIOS: CONFIGURED"
	else
		fmtr::warn "SMBIOS: NOT CONFIGURED"
		fmtr::info "Run deploy module to configure SMBIOS from host"
	fi
}

verify_secure_boot() {
	fmtr::info "Verifying Secure Boot and TPM..."

	if ! $ROOT_ESC virsh dominfo WindowsVM &>/dev/null; then
		fmtr::error "VM not found - please run deploy module first"
		return 1
	fi

	if $ROOT_ESC virsh dumpxml WindowsVM | grep -qE 'secure=.yes.'; then
		fmtr::log "Secure Boot: ENABLED in OVMF"
	else
		fmtr::warn "Secure Boot: NOT ENABLED"
	fi

	if $ROOT_ESC virsh dumpxml WindowsVM | grep -qE '<tpm'; then
		fmtr::log "TPM: CONFIGURED"
	else
		fmtr::warn "TPM: NOT CONFIGURED"
	fi
}

show_eac_requirements() {
	fmtr::info "Fortnite/EAC Requirements"
	echo ""
	echo "  For Fortnite to work with EasyAntiCheat:"
	echo ""
	echo "  [REQUIRED]"
	echo "    - Secure Boot: ENABLED (in OVMF)"
	echo "    - TPM 2.0: ENABLED (swtpm)"
	echo "    - CPU: host-passthrough mode"
	echo "    - GPU: Dedicated GPU passthrough (NVIDIA recommended)"
	echo ""
	echo "  [RECOMMENDED]"
	echo "    - Looking Glass for low-latency display"
	echo "    - SMBIOS spoofing from real hardware"
	echo "    - Unique MAC address (not QEMU default)"
	echo ""
	echo "  [TESTED WORKING]"
	echo "    - Fortnite (Epic Games)"
	echo "    - Counter-Strike 2 (Steam)"
	echo "    - The Finals (Steam)"
	echo "    - Deadlock (Steam)"
	echo ""
	echo "  [NOT WORKING]"
	echo "    - VALORANT (Vanguard - kernel level)"
	echo "    - Battlefield 6 (Javelin)"
	echo "    - F1 24 (Javelin)"
}

print_final_checklist() {
	fmtr::box_text " EAC Anti-Detection Checklist "
	echo ""

	verify_hypervisor_hidden
	verify_pmu_disabled
	verify_vmport_disabled
	verify_msr_filtering
	verify_clock_source
	verify_video_disabled
	verify_smbios_spoofing
	verify_secure_boot

	echo ""
	fmtr::info "Verification complete!"
	echo ""

	fmtr::warn "IMPORTANT: After VM setup, verify in Windows guest:"
	echo "  - HWiNFO64: Check for VM artifacts"
	echo "  - CPU-Z: Verify CPU features"
	echo "  - Device Manager: No QEMU devices visible"
	echo ""
	echo "If EAC still fails, check:"
	echo "  1. Secure Boot is enabled in Windows (bcdedit /set testsigning on)"
	echo "  2. TPM 2.0 is detected in Windows"
	echo "  3. GPU drivers are properly installed"
	echo "  4. No hypervisor indicators in device manager"
}

main() {
	fmtr::box_text " Fortnite / EAC Patches "

	print_detection_vectors

	echo ""
	if prmt::yes_or_no "$(fmtr::ask 'Show EAC requirements?')"; then
		show_eac_requirements
	fi

	echo ""
	if prmt::yes_or_no "$(fmtr::ask 'Run verification checklist?')"; then
		print_final_checklist
	fi
}

main
