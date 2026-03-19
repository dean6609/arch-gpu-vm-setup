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

readonly LG_SRC_DIR="/tmp/lg-b6"

# =============================================================================
# Clone B6 source (shared by client and module builds)
# =============================================================================

clone_lg_b6_source() {
	if [[ -d "$LG_SRC_DIR/.git" ]]; then
		fmtr::log "Looking Glass B6 source already exists at $LG_SRC_DIR"
		return 0
	fi

	if [[ -d "$LG_SRC_DIR" ]]; then
		rm -rf "$LG_SRC_DIR"
	fi

	fmtr::info "Cloning Looking Glass B6..."
	git clone --branch B6 https://github.com/gnif/LookingGlass "$LG_SRC_DIR" 2>&1 | tee -a "$LOG_FILE" || {
		fmtr::error "Failed to clone Looking Glass B6"
		return 1
	}

	cd "$LG_SRC_DIR" || return 1
	git submodule update --init --recursive 2>&1 | tee -a "$LOG_FILE" || {
		fmtr::error "Failed to update submodules"
		cd - >/dev/null
		return 1
	}
	cd - >/dev/null

	fmtr::log "Looking Glass B6 source ready"
}

# =============================================================================
# Install client (from source)
# =============================================================================

install_looking_glass_client() {
	fmtr::info "Compiling Looking Glass B6 client from source..."

	# Build dependencies
	REQUIRED_PKGS_Arch=(
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

	clone_lg_b6_source || return 1

	mkdir -p "$LG_SRC_DIR/client/build"
	cd "$LG_SRC_DIR/client/build" || return 1

	fmtr::info "Configuring client build..."
	cmake ../ -DCMAKE_POLICY_VERSION_MINIMUM=3.5 &>>"$LOG_FILE" || {
		fmtr::error "CMake configuration failed"
		cd - >/dev/null
		return 1
	}

	fmtr::info "Compiling client (this may take a few minutes)..."
	make -j"$(nproc)" &>>"$LOG_FILE" || {
		fmtr::error "Client compilation failed"
		cd - >/dev/null
		return 1
	}

	fmtr::info "Installing client..."
	$ROOT_ESC make install &>>"$LOG_FILE" || {
		fmtr::error "Client installation failed"
		cd - >/dev/null
		return 1
	}

	cd - >/dev/null
	fmtr::log "Looking Glass B6 client installed"
}

# =============================================================================
# Install KVMFR kernel module (from B6 source via DKMS)
# =============================================================================

install_kvmfr_module() {
	fmtr::info "Installing KVMFR kernel module from B6 source..."

	# Ensure DKMS and kernel headers are installed
	REQUIRED_PKGS_Arch=(
		dkms
		linux-zen-headers
	)
	install_req_pkgs "kvmfr-dkms"

	clone_lg_b6_source || return 1

	local module_src="$LG_SRC_DIR/module"

	if [[ ! -d "$module_src" ]]; then
		fmtr::error "KVMFR module source not found at $module_src"
		return 1
	fi

	# Check if kvmfr is already registered in DKMS
	local current_kernel
	current_kernel=$(uname -r)

	if dkms status kvmfr 2>/dev/null | grep -q "installed"; then
		fmtr::info "Removing existing DKMS kvmfr module..."
		$ROOT_ESC dkms remove kvmfr/B6 --all 2>/dev/null || true
	fi

	# Copy module source to DKMS tree
	local dkms_dir="/usr/src/kvmfr-B6"
	$ROOT_ESC rm -rf "$dkms_dir" 2>/dev/null || true
	$ROOT_ESC mkdir -p "$dkms_dir"
	$ROOT_ESC cp -r "$module_src"/* "$dkms_dir/"

	# Create DKMS configuration
	$ROOT_ESC tee "$dkms_dir/dkms.conf" >/dev/null <<'EOF'
PACKAGE_NAME="kvmfr"
PACKAGE_VERSION="B6"
AUTOINSTALL="yes"

BUILT_MODULE_NAME[0]="kvmfr"
DEST_MODULE_LOCATION[0]="/extra"

MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"
CLEAN="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build clean"
EOF

	fmtr::info "Adding kvmfr B6 to DKMS..."
	$ROOT_ESC dkms add kvmfr/B6 2>&1 | tee -a "$LOG_FILE" || {
		fmtr::warn "DKMS add failed (may already exist)"
	}

	fmtr::info "Building kvmfr module for kernel $current_kernel..."
	if $ROOT_ESC dkms build kvmfr/B6 -k "$current_kernel" 2>&1 | tee -a "$LOG_FILE"; then
		fmtr::log "KVMFR module built successfully"
	else
		fmtr::error "DKMS build failed"
		fmtr::info "Attempting manual compilation..."
		install_kvmfr_module_manual
		return $?
	fi

	fmtr::info "Installing kvmfr module..."
	if $ROOT_ESC dkms install kvmfr/B6 -k "$current_kernel" 2>&1 | tee -a "$LOG_FILE"; then
		fmtr::log "KVMFR module installed via DKMS for $current_kernel"
	else
		fmtr::error "DKMS install failed"
		fmtr::info "Attempting manual compilation..."
		install_kvmfr_module_manual
		return $?
	fi
}

install_kvmfr_module_manual() {
	fmtr::info "Building KVMFR module manually..."

	local module_src="$LG_SRC_DIR/module"
	local current_kernel
	current_kernel=$(uname -r)

	cd "$module_src" || return 1

	$ROOT_ESC make -C "/lib/modules/${current_kernel}/build" M="$(pwd)" modules 2>&1 | tee -a "$LOG_FILE" || {
		fmtr::error "Manual module build failed"
		cd - >/dev/null
		return 1
	}

	if [[ -f "$module_src/kvmfr.ko" ]]; then
		$ROOT_ESC mkdir -p "/lib/modules/${current_kernel}/extra"
		$ROOT_ESC cp "$module_src/kvmfr.ko" "/lib/modules/${current_kernel}/extra/"
		$ROOT_ESC depmod -a "$current_kernel"
		fmtr::log "KVMFR module installed manually to /lib/modules/${current_kernel}/extra/"
	else
		fmtr::error "kvmfr.ko not found after build"
		cd - >/dev/null
		return 1
	fi

	cd - >/dev/null
}

# =============================================================================
# Configure KVMFR (modprobe options, udev, modules-load)
# =============================================================================

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

# =============================================================================
# Configure IVSHMEM shared memory
# =============================================================================

configure_ivshmem_tmpfiles() {
	fmtr::info "Configuring IVSHMEM shared memory..."

	printf 'f /dev/shm/looking-glass 0660 root kvm -\n' |
		$ROOT_ESC tee /etc/tmpfiles.d/10-looking-glass.conf >/dev/null

	$ROOT_ESC systemd-tmpfiles --create /etc/tmpfiles.d/10-looking-glass.conf &>>"$LOG_FILE" ||
		fmtr::warn "Failed to create IVSHMEM temp files"

	fmtr::log "IVSHMEM configured"
}

# =============================================================================
# Configure Looking Glass client
# =============================================================================

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

# =============================================================================
# Verify installation
# =============================================================================

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

	# Check kvmfr module is available (loadable)
	if modinfo kvmfr &>/dev/null 2>&1; then
		fmtr::log "KVMFR kernel module: AVAILABLE"
	else
		fmtr::warn "KVMFR kernel module: NOT AVAILABLE (not built for this kernel)"
		all_ok=false
	fi

	# Check kvmfr module config files
	if [[ -f /etc/modules-load.d/kvmfr.conf ]]; then
		fmtr::log "KVMFR autoload config: /etc/modules-load.d/kvmfr.conf EXISTS"
	else
		fmtr::warn "KVMFR autoload config: NOT FOUND"
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
	$ROOT_ESC modprobe kvmfr static_size_mb=64 2>>"$LOG_FILE"
	local modprobe_rc=$?
	sleep 1

	if ((modprobe_rc != 0)); then
		fmtr::warn "modprobe kvmfr FAILED - module not built for kernel $(uname -r)"
		fmtr::info "Run the 'Install KVMFR module' step to build it"
		all_ok=false
	elif [[ -e /dev/kvmfr0 ]]; then
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

# =============================================================================
# Main
# =============================================================================

main() {
	fmtr::box_text " Install Looking Glass B6 "

	fmtr::warn "IMPORTANT: This installs Looking Glass B6 specifically."
	fmtr::info "B7 crashes on AMD GPUs with 'vector.c:123 Out of bounds access'"
	echo ""

	if prmt::yes_or_no "$(fmtr::ask 'Install Looking Glass B6 client (compile from source)?')"; then
		install_looking_glass_client || exit 1
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Install KVMFR kernel module (compile from B6 source)?')"; then
		install_kvmfr_module || exit 1
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Configure KVMFR module (64MB, udev rules)?')"; then
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
