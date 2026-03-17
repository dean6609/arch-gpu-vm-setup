#!/usr/bin/env bash

# =============================================================================
# Module 11: Uninstall
# Completely removes GPU VM setup and restores original configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

uninstall_vfio_config() {
	fmtr::info "Removing VFIO configuration..."

	local files=(
		"/etc/modprobe.d/vfio.conf"
		"/etc/modprobe.d/blacklist-gpu-passthrough.conf"
	)

	for file in "${files[@]}"; do
		if [[ -f "$file" ]]; then
			$ROOT_ESC rm -v "$file" &>>"$LOG_FILE"
			fmtr::log "Removed: $file"
		fi
	done
}

uninstall_mkinitcpio_config() {
	fmtr::info "Restoring mkinitcpio configuration..."

	if grep -q "^MODULES=(vfio vfio_iommu_type1 vfio_pci)" /etc/mkinitcpio.conf 2>/dev/null; then
		$ROOT_ESC sed -i 's/^MODULES=(vfio vfio_iommu_type1 vfio_pci)/MODULES=()/' /etc/mkinitcpio.conf
		fmtr::log "Removed VFIO modules from mkinitcpio.conf"
	fi

	$ROOT_ESC mkinitcpio -P &>>"$LOG_FILE" &&
		fmtr::log "Rebuilt initramfs" ||
		fmtr::warn "Failed to rebuild initramfs"
}

revert_bootloader_params() {
	fmtr::info "Reverting bootloader kernel parameters..."

	detect_bootloader || return 1

	local vfio_regex='(intel_iommu=[^ ]*|iommu=[^ ]*|vfio-pci\.ids=[^ ]*)'

	case $BOOTLOADER_TYPE in
	grub)
		if [[ -f /etc/default/grub ]]; then
			$ROOT_ESC sed -E -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/{
                    s/'"$vfio_regex"'//g
                    s/[[:space:]]+/ /g
                    s/"[[:space:]]+/"
                    s/[[:space:]]+"/"/
                }' /etc/default/grub

			$ROOT_ESC grub-mkconfig -o /boot/grub/grub.cfg &>>"$LOG_FILE"
			fmtr::log "Reverted GRUB config"
		fi
		;;
	systemd-boot)
		for entry in /boot/loader/entries/*.conf; do
			[[ -f "$entry" ]] || continue
			$ROOT_ESC sed -E -i "/^options / {
                    s/$vfio_regex//g;
                    s/[[:space:]]+/ /g;
                    s/[[:space:]]+$//;
                }" "$entry"
		done
		fmtr::log "Reverted systemd-boot entries"
		;;
	limine)
		if [[ -f /etc/default/limine ]]; then
			$ROOT_ESC sed -E -i '/^KERNEL_CMDLINE.*\+/ {
                    s/'"$vfio_regex"'//g;
                    s/[[:space:]]+/ /g;
                }' /etc/default/limine

			if command -v limine-mkinitcpio &>/dev/null; then
				$ROOT_ESC limine-mkinitcpio &>>"$LOG_FILE"
			fi
			fmtr::log "Reverted Limine config"
		fi
		;;
	esac
}

uninstall_looking_glass() {
	fmtr::info "Uninstalling Looking Glass..."

	local aur_helper
	if command -v yay &>/dev/null; then
		aur_helper="yay"
	elif command -v paru &>/dev/null; then
		aur_helper="paru"
	else
		fmtr::warn "No AUR helper found, skipping package removal"
		return 0
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Remove Looking Glass packages?')"; then
		$ROOT_ESC "$aur_helper" -R --noconfirm looking-glass looking-glass-module-dkms &>>"$LOG_FILE" &&
			fmtr::log "Removed Looking Glass packages" ||
			fmtr::warn "Failed to remove Looking Glass packages"
	fi

	local config_files=(
		"/etc/modules-load.d/kvmfr.conf"
		"/etc/modprobe.d/kvmfr.conf"
		"/etc/tmpfiles.d/10-looking-glass.conf"
	)

	for file in "${config_files[@]}"; do
		if [[ -f "$file" ]]; then
			$ROOT_ESC rm -v "$file" &>>"$LOG_FILE"
		fi
	done
}

remove_vm() {
	fmtr::info "Removing VM..."

	local vm_name="WindowsVM"

	if virsh dominfo "$vm_name" &>/dev/null; then
		if virsh list --all | grep -q "$vm_name.*running"; then
			fmtr::info "Shutting down VM..."
			virsh shutdown "$vm_name" &>>"$LOG_FILE"
			sleep 5
			virsh destroy "$vm_name" &>>"$LOG_FILE" || true
		fi

		if prmt::yes_or_no "$(fmtr::ask 'Remove VM definition?')"; then
			virsh undefine "$vm_name" &>>"$LOG_FILE" &&
				fmtr::log "Removed VM definition" ||
				fmtr::warn "Failed to remove VM"
		fi
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Remove VM disk image?')"; then
		if [[ -f "/var/lib/libvirt/images/${vm_name}.img" ]]; then
			$ROOT_ESC rm -v "/var/lib/libvirt/images/${vm_name}.img" &>>"$LOG_FILE" &&
				fmtr::log "Removed VM disk" ||
				fmtr::warn "Failed to remove VM disk"
		fi
	fi
}

remove_installed_files() {
	fmtr::info "Removing installed files..."

	local directories=(
		"/opt/gpu-vm-setup"
	)

	for dir in "${directories[@]}"; do
		if [[ -d "$dir" ]]; then
			$ROOT_ESC rm -rfv "$dir" &>>"$LOG_FILE" &&
				fmtr::log "Removed: $dir" ||
				fmtr::warn "Failed to remove: $dir"
		fi
	done

	local config_file="${SCRIPT_DIR}/config.conf"
	if [[ -f "$config_file" ]]; then
		rm -v "$config_file" &>>"$LOG_FILE"
		fmtr::log "Removed config file"
	fi
}

restore_from_backup() {
	fmtr::info "Checking for backups..."

	local backup_dir="/var/backups/gpu-vm-setup"

	if [[ -d "$backup_dir" ]]; then
		local latest_backup
		latest_backup=$(ls -td "$backup_dir"/setup-* 2>/dev/null | head -1)

		if [[ -n "$latest_backup" ]] && prmt::yes_or_no "$(fmtr::ask "Restore from backup: $latest_backup?")"; then
			for file in "$latest_backup"/*; do
				[[ -f "$file" ]] || continue
				local filename
				filename=$(basename "$file")
				$ROOT_ESC cp -v "$file" "/etc/${filename}" &>>"$LOG_FILE" &&
					fmtr::log "Restored: /etc/${filename}" ||
					fmtr::warn "Failed to restore: /etc/${filename}"
			done
			fmtr::log "Backup restored"
		fi
	else
		fmtr::info "No backups found"
	fi
}

main() {
	fmtr::box_text " Uninstall GPU VM Setup "

	fmtr::warn "This will remove all GPU passthrough configuration!"
	echo ""

	if ! prmt::yes_or_no "$(fmtr::ask 'Proceed with uninstallation?')"; then
		fmtr::info "Uninstall cancelled"
		exit 0
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Stop and remove VM?')"; then
		remove_vm
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Remove VFIO configuration?')"; then
		uninstall_vfio_config
		uninstall_mkinitcpio_config
		revert_bootloader_params
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Remove Looking Glass?')"; then
		uninstall_looking_glass
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Remove installed files (/opt/gpu-vm-setup)?')"; then
		remove_installed_files
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Restore from backup?')"; then
		restore_from_backup
	fi

	fmtr::log "Uninstallation complete!"
	fmtr::warn "REBOOT recommended to fully remove VFIO and restore normal operation"
}

main
