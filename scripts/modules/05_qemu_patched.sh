#!/usr/bin/env bash

# =============================================================================
# Module 05: Compile QEMU with Anti-Detection Patches
# Clones QEMU, applies patches, compiles with SPICE and USB support
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

readonly QEMU_VERSION="v10.2.0"
readonly QEMU_DIR="/opt/gpu-vm-setup/qemu"
readonly QEMU_INSTALL_DIR="/opt/gpu-vm-setup/emulator"

REQUIRED_BUILD_PKGS_Arch=(
	base-devel
	ninja
	python
	python-sphinx
	python-sphinx_rtd_theme
	git
	glib2
	libevdev
	spice
	gtk3
	libusb
	usbredir
	PulseAudio
	SDL2
	libjpeg
	libpng
	vde2
	libattr
	libcap
	libseccomp
	gnutls
	libiscsi
	libnfs
	libcurl
	openssl
	libtasn1
	libjpeg-turbo
	lzma
	zstd
	snappy
	bzip2
	libdrm
	libgbm
	virglrenderer
	mesa
)

download_qemu() {
	fmtr::info "Downloading QEMU $QEMU_VERSION..."

	if [[ -d "$QEMU_DIR" ]]; then
		fmtr::log "QEMU directory already exists, using existing source"
		return 0
	fi

	$ROOT_ESC mkdir -p "$(dirname "$QEMU_DIR")"
	$ROOT_ESC chown "$USER:$USER" "$(dirname "$QEMU_DIR")"

	fmtr::info "Cloning QEMU (this may take a few minutes)..."

	if git clone --depth=1 --branch "$QEMU_VERSION" \
		"https://gitlab.com/qemu-project/qemu.git" \
		"$QEMU_DIR" 2>&1 | tee -a "$LOG_FILE"; then
		fmtr::log "QEMU source downloaded to $QEMU_DIR"
	else
		fmtr::error "Failed to clone QEMU"
		return 1
	fi
}

apply_qemu_patches() {
	fmtr::info "Applying QEMU patches for anti-detection..."

	local patch_dir="${SCRIPT_DIR}/patches/QEMU"
	local cpu_patch=""

	if [[ "$CPU_MANUFACTURER" == "AMD" ]]; then
		cpu_patch="$patch_dir/AMD-${QEMU_VERSION}.patch"
	else
		cpu_patch="$patch_dir/Intel-${QEMU_VERSION}.patch"
	fi

	if [[ -f "$cpu_patch" ]]; then
		cd "$QEMU_DIR" || return 1
		git apply "$cpu_patch" &>>"$LOG_FILE" &&
			fmtr::log "Applied CPU-specific patch" ||
			fmtr::warn "Failed to apply CPU patch (may already be patched or not found)"
		cd - >/dev/null
	else
		fmtr::info "No specific patch found at $cpu_patch"
		fmtr::info "Applying generic anti-detection patches..."

		cd "$QEMU_DIR" || return 1

		if [[ -f "$patch_dir/kvm-clock-disable.patch" ]]; then
			git apply "$patch_dir/kvm-clock-disable.patch" &>>"$LOG_FILE" &&
				fmtr::log "Applied kvm-clock disable patch"
		fi

		if [[ -f "$patch_dir/hypervisor-bit-clear.patch" ]]; then
			git apply "$patch_dir/hypervisor-bit-clear.patch" &>>"$LOG_FILE" &&
				fmtr::log "Applied hypervisor bit clear patch"
		fi

		cd - >/dev/null
	fi
}

configure_qemu() {
	fmtr::info "Configuring QEMU build..."

	cd "$QEMU_DIR" || return 1

	local configure_opts=(
		--prefix="$QEMU_INSTALL_DIR"
		--target-list=x86_64-softmmu
		--enable-spice
		--enable-libusb
		--enable-usb-redir
		--enable-kvm
		--disable-werror
		--disable-docs
	)

	if [[ -f "/usr/lib/liburing.so" ]]; then
		configure_opts+=(--enable-linux-io-uring)
	fi

	./configure "${configure_opts[@]}" &>>"$LOG_FILE" ||
		{
			fmtr::error "QEMU configuration failed"
			cd - >/dev/null
			return 1
		}

	cd - >/dev/null
	fmtr::log "QEMU configured successfully"
}

compile_qemu() {
	fmtr::info "Compiling QEMU (this may take a while)..."

	cd "$QEMU_DIR" || return 1

	local cores
	cores=$(nproc)

	make -j"$cores" &>>"$LOG_FILE" ||
		{
			fmtr::error "QEMU compilation failed"
			cd - >/dev/null
			return 1
		}

	cd - >/dev/null

	fmtr::log "QEMU compiled successfully"
}

install_qemu() {
	fmtr::info "Installing QEMU..."

	cd "$QEMU_DIR" || return 1

	$ROOT_ESC make install &>>"$LOG_FILE" ||
		{
			fmtr::error "QEMU installation failed"
			cd - >/dev/null
			return 1
		}

	cd - >/dev/null

	$ROOT_ESC mkdir -p "$QEMU_INSTALL_DIR/bin"

	if [[ -f "$QEMU_DIR/build/qemu-system-x86_64" ]]; then
		$ROOT_ESC cp "$QEMU_DIR/build/qemu-system-x86_64" "$QEMU_INSTALL_DIR/bin/" ||
			fmtr::warn "Binary copy failed"
	elif [[ -x "$QEMU_INSTALL_DIR/bin/qemu-system-x86_64" ]]; then
		fmtr::log "QEMU installed to $QEMU_INSTALL_DIR/bin/"
	fi

	fmtr::log "QEMU installed to $QEMU_INSTALL_DIR"
}

spoof_disk_models() {
	fmtr::info "Applying disk model spoofing..."

	local qemu_source="$QEMU_DIR"

	if grep -q 'Samsung SSD' "$qemu_source/hw/ide/core.c" 2>/dev/null; then
		fmtr::log "Disk spoofing already applied"
		return 0
	fi

	cat >>"$qemu_source/hw/ide/core.c" <<'EOF'

/* Disk Model Spoofing - Anti-Detection */
static const char *spoofed_disk_models[] = {
    "Samsung SSD 990 PRO 1TB",
    "WD_BLACK SN850X 1TB",
    "Crucial P5 Plus 500GB",
    "Kingston A400 480GB",
    "Sabrent Rocket 4TB",
};

static const char *get_spoofed_model(void) {
    return spoofed_disk_models[arc4random_uniform(sizeof(spoofed_disk_models)/sizeof(char*))];
}
EOF

	fmtr::log "Disk model spoofing added"
}

main() {
	fmtr::box_text " Compile QEMU with Patches "

	install_req_pkgs "qemu-build"

	if prmt::yes_or_no "$(fmtr::ask 'Download QEMU source?')"; then
		download_qemu || exit 1
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Apply anti-detection patches?')"; then
		apply_qemu_patches
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Configure QEMU build?')"; then
		configure_qemu || exit 1
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Compile QEMU? (takes 10-30 minutes)')"; then
		compile_qemu || exit 1
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Install QEMU?')"; then
		install_qemu
		fmtr::log "QEMU installed to: $QEMU_INSTALL_DIR"
		fmtr::info "Use: $QEMU_INSTALL_DIR/bin/qemu-system-x86_64"
	fi

	fmtr::info "QEMU compilation and installation complete!"
}

main
