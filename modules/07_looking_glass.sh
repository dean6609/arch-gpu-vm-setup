#!/usr/bin/env bash

# =============================================================================
# Module 07: Install Looking Glass
# Low-latency VM display using IVSHMEM/KVMFR
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

install_looking_glass_aur() {
	fmtr::info "Installing Looking Glass from AUR..."

	local aur_helper
	if command -v yay &>/dev/null; then
		aur_helper="yay"
	elif command -v paru &>/dev/null; then
		aur_helper="paru"
	else
		fmtr::error "No AUR helper found (yay/paru)"
		return 1
	fi

	"$aur_helper" --noconfirm -S looking-glass looking-glass-module-dkms 2>&1 | tee -a "$LOG_FILE" ||
		{
			fmtr::error "Failed to install Looking Glass"
			return 1
		}

	fmtr::log "Looking Glass installed"
}

configure_kvmfr_module() {
	fmtr::info "Configuring KVMFR kernel module..."

	local modules_conf="/etc/modules-load.d/kvmfr.conf"
	local kvmfr_conf="/etc/modprobe.d/kvmfr.conf"

	echo "kvmfr" | $ROOT_ESC tee "$modules_conf" >/dev/null
	fmtr::log "Added kvmfr to $modules_conf"

	printf 'options kvmfr static_size_mb=%s\n' "${LOOKING_GLASS_SIZE:-32}" |
		$ROOT_ESC tee "$kvmfr_conf" >/dev/null
	fmtr::log "Added KVMFR options to $kvmfr_conf"
}

configure_ivshmem_tmpfiles() {
	fmtr::info "Configuring IVSHMEM shared memory..."

	local tmpfiles_conf="/etc/tmpfiles.d/10-looking-glass.conf"

	printf 'f /dev/shm/looking-glass 0660 root kvm -\n' |
		$ROOT_ESC tee "$tmpfiles_conf" >/dev/null

	$ROOT_ESC systemd-tmpfiles --create "$tmpfiles_conf" &>>"$LOG_FILE" ||
		fmtr::warn "Failed to create IVSHMEM temp files"

	fmtr::log "IVSHMEM configured"
}

configure_looking_glass_client() {
	fmtr::info "Configuring Looking Glass client..."

	local lg_config_dir="$HOME/.config/looking-glass"
	local lg_config="$lg_config_dir/client.ini"

	mkdir -p "$lg_config_dir"

	if [[ -f "$lg_config" ]]; then
		fmtr::log "Looking Glass config already exists"
		return 0
	fi

	cat >"$lg_config" <<'EOF'
[general]
forceFullscreen=false

[input]
captureKey=KEY_SCROLLLOCK

[display]
forceEgl=false
skipInternalFramePause=false

[audio]
enable=true
EOF

	fmtr::log "Created Looking Glass client config at $lg_config"
	fmtr::info "You can change captureKey in the config (KEY_SCROLLLOCK, KEY_RIGHTCTRL, etc.)"
}

show_ivshmem_size_guide() {
	fmtr::info "IVSHMEM Size Guide:"
	echo ""
	echo "  Resolution      | SDR  | HDR"
	echo "  ----------------|------|-----"
	echo "  1920x1080       | 32MB | 64MB"
	echo "  1920x1200       | 32MB | 64MB"
	echo "  2560x1440       | 64MB | 128MB"
	echo "  3840x2160       | 128MB| 256MB"
	echo ""
}

set_ivshmem_size() {
	show_ivshmem_size_guide

	echo ""
	local options=("32" "64" "128" "256")
	local size_labels=("32MB - 1080p SDR" "64MB - 1080p HDR / 1440p SDR" "128MB - 1440p HDR / 4K SDR" "256MB - 4K HDR")

	fmtr::info "Select IVSHMEM size:"
	for ((i = 0; i < ${#options[@]}; i++)); do
		printf '  %d) %s\n' $((i + 1)) "${size_labels[$i]}"
	done

	local selection
	read -rp "$(fmtr::ask_inline 'Selection: ')" selection

	if ((selection >= 1 && selection <= ${#options[@]})); then
		LOOKING_GLASS_SIZE="${options[$((selection - 1))]}"
		export LOOKING_GLASS_SIZE
		write_config
		fmtr::log "IVSHMEM size set to ${LOOKING_GLASS_SIZE}MB"
	else
		fmtr::error "Invalid selection"
	fi
}

verify_looking_glass() {
	fmtr::info "Verifying Looking Glass installation..."

	if command -v looking-glass &>/dev/null; then
		fmtr::log "Looking Glass client: installed"
	else
		fmtr::warn "Looking Glass client: not found in PATH"
	fi

	if lsmod | grep -q "^kvmfr "; then
		fmtr::log "KVMFR module: loaded"
	else
		fmtr::warn "KVMFR module: not loaded (load with 'modprobe kvmfr')"
	fi

	if [[ -c "/dev/kvmfr0" ]]; then
		fmtr::log "KVMFR device: /dev/kvmfr0 exists"
	elif [[ -c "/dev/shm/looking-glass" ]]; then
		fmtr::log "IVSHMEM device: /dev/shm/looking-glass exists"
	else
		fmtr::warn "Neither KVMFR nor IVSHMEM device found"
	fi

	if groups "$USER" | grep -qw "kvm"; then
		fmtr::log "User in kvm group: yes"
	else
		fmtr::warn "User not in kvm group"
	fi
}

main() {
	fmtr::box_text " Install Looking Glass "

	if ! command -v yay &>/dev/null && ! command -v paru &>/dev/null; then
		fmtr::error "AUR helper (yay/paru) not found. Install it first."
		fmtr::info "Run: git clone https://aur.archlinux.org/yay.git /tmp/yay && cd /tmp/yay && makepkg -si"
		exit 1
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Install Looking Glass from AUR?')"; then
		install_looking_glass_aur || exit 1
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Configure KVMFR module?')"; then
		configure_kvmfr_module
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Configure IVSHMEM shared memory?')"; then
		configure_ivshmem_tmpfiles
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Set IVSHMEM size?')"; then
		set_ivshmem_size
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Configure Looking Glass client?')"; then
		configure_looking_glass_client
	fi

	verify_looking_glass

	fmtr::warn "Reboot or load KVMFR module for changes to take effect:"
	fmtr::info "  sudo modprobe kvmfr static_size_mb=${LOOKING_GLASS_SIZE:-32}"
}

main
