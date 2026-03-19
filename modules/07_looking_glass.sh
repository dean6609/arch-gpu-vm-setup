#!/usr/bin/env bash

# =============================================================================
# Module 07: Install Looking Glass B6
# Low-latency VM display using IVSHMEM/KVMFR
# IMPORTANT: Always install B6, NOT B7 (B7 crashes on AMD GPUs)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

install_looking_glass_aur() {
	fmtr::info "Installing Looking Glass B6 from AUR..."

	local aur_helper
	if command -v yay &>/dev/null; then
		aur_helper="yay"
	elif command -v paru &>/dev/null; then
		aur_helper="paru"
	else
		fmtr::error "No AUR helper found (yay/paru)"
		return 1
	fi

	# Try AUR packages for B6 specifically, skip integrity checks
	fmtr::info "Attempting AUR install of looking-glass-b6..."
	if "$aur_helper" --noconfirm --skipinteg -S looking-glass-b6 looking-glass-module-dkms 2>&1 | tee -a "$LOG_FILE"; then
		fmtr::log "Looking Glass B6 installed from AUR"
		return 0
	fi

	fmtr::warn "AUR B6 package not available, falling back to source compilation..."
	install_looking_glass_source
}

install_looking_glass_source() {
	fmtr::info "Compiling Looking Glass B6 from source..."

	# Install build dependencies
	local REQUIRED_PKGS_Arch=(
		cmake
		gcc
		fontconfig
		libgl
		spice-protocol
		nettle
		pkg-config
		wayland
		wayland-protocols
		libxkbcommon
		libsamplerate
	)
	install_req_pkgs "looking-glass-build"

	local lg_dir="/tmp/lg-b6"

	if [[ -d "$lg_dir" ]]; then
		fmtr::info "Removing existing LG source directory..."
		rm -rf "$lg_dir"
	fi

	fmtr::info "Cloning Looking Glass B6..."
	git clone --branch B6 https://github.com/gnif/LookingGlass "$lg_dir" 2>&1 | tee -a "$LOG_FILE" || {
		fmtr::error "Failed to clone Looking Glass B6"
		return 1
	}

	cd "$lg_dir" || return 1
	git submodule update --init --recursive 2>&1 | tee -a "$LOG_FILE" || {
		fmtr::error "Failed to update submodules"
		cd - >/dev/null
		return 1
	}

	mkdir -p client/build
	cd client/build || return 1

	fmtr::info "Configuring build..."
	cmake ../ -DCMAKE_POLICY_VERSION_MINIMUM=3.5 &>>"$LOG_FILE" || {
		fmtr::error "CMake configuration failed"
		cd - >/dev/null
		return 1
	}

	fmtr::info "Compiling (this may take a few minutes)..."
	make -j"$(nproc)" &>>"$LOG_FILE" || {
		fmtr::error "Compilation failed"
		cd - >/dev/null
		return 1
	}

	fmtr::info "Installing..."
	$ROOT_ESC make install &>>"$LOG_FILE" || {
		fmtr::error "Installation failed"
		cd - >/dev/null
		return 1
	}

	cd - >/dev/null

	fmtr::log "Looking Glass B6 compiled and installed from source"
}

configure_kvmfr_module() {
	fmtr::info "Configuring KVMFR kernel module (64MB)..."

	echo "kvmfr" | $ROOT_ESC tee /etc/modules-load.d/kvmfr.conf >/dev/null
	fmtr::log "Added kvmfr to /etc/modules-load.d/kvmfr.conf"

	echo "options kvmfr static_size_mb=64" | $ROOT_ESC tee /etc/modprobe.d/kvmfr.conf >/dev/null
	fmtr::log "Set KVMFR size to 64MB in /etc/modprobe.d/kvmfr.conf"

	# Udev rule for device permissions
	echo "KERNEL==\"kvmfr0\", OWNER=\"${USER}\", GROUP=\"kvm\", MODE=\"0660\"" |
		$ROOT_ESC tee /etc/udev/rules.d/99-kvmfr.rules >/dev/null
	fmtr::log "Created udev rule: /etc/udev/rules.d/99-kvmfr.rules"

	$ROOT_ESC udevadm control --reload-rules 2>/dev/null || true
	fmtr::log "Reloaded udev rules"
}

configure_ivshmem_tmpfiles() {
	fmtr::info "Configuring IVSHMEM shared memory..."

	printf 'f /dev/shm/looking-glass 0660 root kvm -\n' |
		$ROOT_ESC tee /etc/tmpfiles.d/10-looking-glass.conf >/dev/null

	$ROOT_ESC systemd-tmpfiles --create /etc/tmpfiles.d/10-looking-glass.conf &>>"$LOG_FILE" ||
		fmtr::warn "Failed to create IVSHMEM temp files"

	fmtr::log "IVSHMEM configured"
}

configure_looking_glass_client() {
	fmtr::info "Configuring Looking Glass client..."

	local lg_config_dir="$HOME/.config/looking-glass"
	local lg_config="$lg_config_dir/client.ini"

	mkdir -p "$lg_config_dir"

	cat >"$lg_config" <<'EOF'
[input]
escapeKey=KEY_RIGHTCTRL

[spice]
enable=true
host=127.0.0.1
port=5900

[win]
autoScreenSize=no
w=1920
h=1080

[app]
shmFile=/dev/kvmfr0
EOF

	fmtr::log "Created Looking Glass client config at $lg_config"
	echo ""
	fmtr::info "Looking Glass Client Configuration:"
	fmtr::info "  - Right Ctrl captures/releases mouse and keyboard inside LG window"
	fmtr::info "  - The LG window is used ONLY as a management tool"
	fmtr::info "  - For actual gaming, switch your monitor's physical input to the dGPU output"
	fmtr::info "  - This avoids CPU overhead from rendering a duplicate display in Linux"
}

verify_looking_glass() {
	fmtr::info "Verifying Looking Glass installation..."
	echo ""

	local all_ok=true

	# Check binary
	if command -v looking-glass-client &>/dev/null; then
		fmtr::log "Looking Glass client binary: FOUND"
	else
		fmtr::warn "Looking Glass client binary: NOT FOUND in PATH"
		all_ok=false
	fi

	# Check kvmfr module config
	if [[ -f /etc/modules-load.d/kvmfr.conf ]]; then
		fmtr::log "KVMFR module config: /etc/modules-load.d/kvmfr.conf EXISTS"
	else
		fmtr::warn "KVMFR module config: NOT FOUND"
		all_ok=false
	fi

	# Check client config
	if [[ -f "$HOME/.config/looking-glass/client.ini" ]] &&
		grep -q "escapeKey=KEY_RIGHTCTRL" "$HOME/.config/looking-glass/client.ini" 2>/dev/null; then
		fmtr::log "Client config with escapeKey=KEY_RIGHTCTRL: OK"
	else
		fmtr::warn "Client config: NOT FOUND or missing escapeKey"
		all_ok=false
	fi

	# Load kvmfr module and check device
	fmtr::info "Loading kvmfr module..."
	$ROOT_ESC modprobe kvmfr static_size_mb=64 2>/dev/null || true
	sleep 1

	if [[ -e /dev/kvmfr0 ]]; then
		fmtr::log "KVMFR device: /dev/kvmfr0 EXISTS"
	else
		fmtr::warn "KVMFR device: /dev/kvmfr0 NOT FOUND after modprobe"
		all_ok=false
	fi

	# Check user groups
	if groups "$USER" | grep -qw "kvm"; then
		fmtr::log "User in kvm group: YES"
	else
		fmtr::warn "User NOT in kvm group (run: sudo usermod -aG kvm $USER)"
		all_ok=false
	fi

	echo ""
	if [[ "$all_ok" == true ]]; then
		fmtr::log "All Looking Glass checks passed!"
	else
		fmtr::warn "Some checks failed - review the warnings above"
	fi
}

main() {
	fmtr::box_text " Install Looking Glass B6 "

	fmtr::warn "IMPORTANT: This installs Looking Glass B6 specifically."
	fmtr::info "B7 crashes on AMD GPUs with 'vector.c:123 Out of bounds access'"
	echo ""

	if ! command -v yay &>/dev/null && ! command -v paru &>/dev/null; then
		fmtr::warn "No AUR helper found - will compile from source"
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Install Looking Glass B6?')"; then
		install_looking_glass_aur || {
			fmtr::warn "AUR install failed, trying source compilation..."
			install_looking_glass_source || exit 1
		}
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Configure KVMFR module (64MB)?')"; then
		configure_kvmfr_module
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Configure IVSHMEM shared memory?')"; then
		configure_ivshmem_tmpfiles
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Configure Looking Glass client (Right Ctrl capture)?')"; then
		configure_looking_glass_client
	fi

	echo ""
	verify_looking_glass
}

main
