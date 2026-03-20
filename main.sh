#!/usr/bin/env bash

# =============================================================================
# GPU VM Setup - Main Entry Point
# Interactive menu for GPU passthrough gaming VM setup on Arch Linux
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

check_non_root() {
	if [[ $EUID -eq 0 ]]; then
		fmtr::fatal "Do not run as root. Run as a regular user and enter password when prompted."
		exit 1
	fi
}

main_menu() {
	local options=(
		"Exit"
		"Prerequisites Check"
		"BIOS Configuration Guide"
		"Virtualization Setup (QEMU/KVM/libvirt)"
		"VFIO / GPU Passthrough Configuration"
		"GPU Binding Management (vm/host/none)"
		"Compile QEMU (with anti-detection patches)"
		"Compile EDK2/OVMF (patched firmware)"
		"Install Looking Glass"
		"Deploy Windows VM"
		"Fortnite/EAC Specific Patches"
		"System Diagnostics"
		"Uninstall Everything"
		"Gaming Mode"
	)
	readonly options

	while :; do
		clear
		fmtr::box_text " >> GPU Passthrough Gaming << "
		echo ""
		fmtr::info "CPU: $CPU_MANUFACTURER ($CPU_VENDOR_ID) | Distro: $DISTRO | Bootloader: $BOOTLOADER_TYPE"
		echo ""

		for ((i = 1; i < ${#options[@]} - 1; i++)); do
			printf '  %b[%d]%b %s\n' "$TEXT_BRIGHT_YELLOW" "$i" "$RESET" "${options[i]}"
		done
		printf '  %b[G]%b %s\n' "$TEXT_BRIGHT_MAGENTA" "$RESET" "${options[${#options[@]} - 1]}"
		printf '\n  %b[%d]%b %s\n\n' "$TEXT_BRIGHT_RED" 0 "$RESET" "${options[0]}"

		local choice
		read -rp "  Enter your choice [0-12, G]: " choice
		clear

		case $choice in
		1)
			fmtr::box_text "${options[1]}"
			./modules/00_prereq_check.sh
			;;
		2)
			fmtr::box_text "${options[2]}"
			./modules/01_bios_guide.sh
			;;
		3)
			fmtr::box_text "${options[3]}"
			./modules/02_virtualization.sh
			;;
		4)
			fmtr::box_text "${options[4]}"
			./modules/03_vfio_setup.sh
			;;
		5)
			fmtr::box_text "${options[5]}"
			./modules/04_gpu_bind.sh
			;;
		6)
			fmtr::box_text "${options[6]}"
			./modules/05_qemu_patched.sh
			;;
		7)
			fmtr::box_text "${options[7]}"
			./modules/06_edk2_patched.sh
			;;
		8)
			fmtr::box_text "${options[8]}"
			./modules/07_looking_glass.sh
			;;
		9)
			fmtr::box_text "${options[9]}"
			./modules/08_deploy_vm.sh
			;;
		10)
			fmtr::box_text "${options[10]}"
			./modules/09_fortnite_patches.sh
			;;
		11)
			fmtr::box_text "${options[11]}"
			./modules/10_diagnostics.sh
			;;
		12)
			fmtr::box_text "${options[12]}"
			./modules/11_uninstall.sh
			;;
		G | g)
			if [[ ! -f "${SCRIPT_DIR}/gaming-mode.conf" ]]; then
				./gaming-mode-setup.sh
			fi
			if [[ -f "${SCRIPT_DIR}/gaming-mode.conf" ]]; then
				./gaming-mode.sh
			fi
			;;
		0)
			prmt::yes_or_no "$(fmtr::ask 'Do you want to clear the logs directory?')" &&
				rm -f -- "${LOG_PATH}"/*.log
			exit 0
			;;
		*) fmtr::error "Invalid option, please try again." ;;
		esac

		prmt::quick_prompt "$(fmtr::info 'Press any key to continue...')"
	done
}

main() {
	check_non_root
	detect_bootloader || fmtr::warn "Could not detect bootloader, some features may not work."
	main_menu
}

main
