#!/usr/bin/env bash

# =============================================================================
# Module 06: Compile EDK2/OVMF (Patched Firmware)
# Builds OVMF with Secure Boot, TPM2, and anti-detection patches
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

readonly EDK2_VERSION="edk2-stable202602"
readonly EDK2_DIR="/opt/gpu-vm-setup/edk2"
readonly EDK2_INSTALL_DIR="/opt/gpu-vm-setup/firmware"

REQUIRED_BUILD_PKGS_Arch=(
	base-devel
	python
	git
	nasm
	uuidgen
	libelf
	pciutils
	virt-firmware
)

download_edk2() {
	fmtr::info "Downloading EDK2 $EDK2_VERSION..."

	if [[ -d "$EDK2_DIR" ]]; then
		fmtr::log "EDK2 directory already exists, using existing source"
	else
		$ROOT_ESC mkdir -p "$(dirname "$EDK2_DIR")"
		$ROOT_ESC chown "$USER:$USER" "$(dirname "$EDK2_DIR")"

		fmtr::info "Cloning EDK2 (this may take a few minutes)..."

		if ! git clone --depth=1 --branch "$EDK2_VERSION" \
			"https://github.com/tianocore/edk2.git" \
			"$EDK2_DIR" 2>&1 | tee -a "$LOG_FILE"; then
			fmtr::error "Failed to clone EDK2"
			return 1
		fi
	fi

	fmtr::info "Initializing submodules (this may take a few minutes)..."

	cd "$EDK2_DIR" || return 1
	git submodule update --init --depth=1 --jobs="$(nproc)" 2>&1 | tee -a "$LOG_FILE"
	cd - >/dev/null

	fmtr::log "EDK2 source ready at $EDK2_DIR"
}

setup_edk2_build() {
	fmtr::info "Setting up EDK2 build environment..."

	cd "$EDK2_DIR" || return 1

	if [[ ! -d "BaseTools/Build" ]]; then
		make -C BaseTools -j$(nproc) &>>"$LOG_FILE" ||
			{
				fmtr::error "Failed to build BaseTools"
				cd - >/dev/null
				return 1
			}
	fi

	source ./edksetup.sh &>>"$LOG_FILE" ||
		{
			fmtr::error "Failed to source edksetup.sh"
			cd - >/dev/null
			return 1
		}

	cd - >/dev/null
	fmtr::log "EDK2 build environment ready"
}

apply_edk2_patches() {
	fmtr::info "Applying EDK2 patches..."

	local patch_dir="${SCRIPT_DIR}/patches/EDK2"
	local cpu_patch=""

	if [[ "$CPU_MANUFACTURER" == "AMD" ]]; then
		cpu_patch="$patch_dir/AMD-${EDK2_VERSION}.patch"
	else
		cpu_patch="$patch_dir/Intel-${EDK2_VERSION}.patch"
	fi

	if [[ -f "$cpu_patch" ]]; then
		cd "$EDK2_DIR" || return 1
		git apply "$cpu_patch" &>>"$LOG_FILE" &&
			fmtr::log "Applied CPU-specific EDK2 patch" ||
			fmtr::warn "Failed to apply EDK2 patch"
		cd - >/dev/null
	else
		fmtr::info "No specific patch found, applying generic patches..."

		cd "$EDK2_DIR" || return 1

		if [[ -f "$patch_dir/ovmf-spoof.patch" ]]; then
			git apply "$patch_dir/ovmf-spoof.patch" &>>"$LOG_FILE" &&
				fmtr::log "Applied OVMF spoof patch" ||
				true
		fi

		cd - >/dev/null
	fi
}

build_ovmf() {
	fmtr::info "Building OVMF firmware..."

	cd "$EDK2_DIR" || return 1

	export WORKSPACE="$EDK2_DIR"
	export EDK_TOOLS_PATH="$EDK2_DIR/BaseTools"
	export CONF_PATH="$EDK2_DIR/Conf"

	local build_cmd="build"
	local build_opts=(
		-a X64
		-p OvmfPkg/OvmfPkgX64.dsc
		-b RELEASE
		-t GCC5
		-n 0
		--quiet
	)

	if [[ "$CPU_MANUFACTURER" == "AMD" ]]; then
		build_opts+=(
			--define SECURE_BOOT_ENABLE=TRUE
			--define SMM_REQUIRE=TRUE
		)
	else
		build_opts+=(
			--define SECURE_BOOT_ENABLE=TRUE
			--define TPM1_ENABLE=TRUE
			--define TPM2_ENABLE=TRUE
			--define SMM_REQUIRE=TRUE
		)
	fi

	$build_cmd "${build_opts[@]}" &>>"$LOG_FILE" ||
		{
			fmtr::error "OVMF build failed"
			cd - >/dev/null
			return 1
		}

	cd - >/dev/null

	fmtr::log "OVMF built successfully"
}

install_ovmf() {
	fmtr::info "Installing OVMF firmware..."

	$ROOT_ESC mkdir -p "$EDK2_INSTALL_DIR"

	local build_dir="$EDK2_DIR/Build/OvmfX64/RELEASE_GCC5/FV"

	if [[ -f "$build_dir/OVMF_CODE.fd" ]]; then
		$ROOT_ESC cp "$build_dir/OVMF_CODE.fd" "$EDK2_INSTALL_DIR/"
		$ROOT_ESC cp "$build_dir/OVMF_VARS.fd" "$EDK2_INSTALL_DIR/"

		$ROOT_ESC qemu-img convert -f raw -O qcow2 \
			"$EDK2_INSTALL_DIR/OVMF_CODE.fd" \
			"$EDK2_INSTALL_DIR/OVMF_CODE.qcow2" 2>/dev/null || true

		$ROOT_ESC qemu-img convert -f raw -O qcow2 \
			"$EDK2_INSTALL_DIR/OVMF_VARS.fd" \
			"$EDK2_INSTALL_DIR/OVMF_VARS.qcow2" 2>/dev/null || true

		fmtr::log "OVMF installed to: $EDK2_INSTALL_DIR"
	else
		fmtr::error "OVMF firmware files not found after build"
		return 1
	fi
}

inject_secure_boot_certs() {
	fmtr::info "Injecting Secure Boot certificates..."

	if ! command -v virt-fw-vars &>/dev/null; then
		fmtr::warn "virt-fw-vars not found, skipping Secure Boot certificate injection"
		fmtr::info "Install virt-firmware package for Secure Boot support"
		return 0
	fi

	local vars_file="$EDK2_INSTALL_DIR/OVMF_VARS.qcow2"

	if [[ ! -f "$vars_file" ]]; then
		fmtr::warn "OVMF_VARS.qcow2 not found, skipping certificate injection"
		return 0
	fi

	local temp_dir
	temp_dir=$(mktemp -d)
	trap "rm -rf $temp_dir" RETURN

	local ms_certs=(
		"https://raw.githubusercontent.com/microsoft/secureboot_objects/main/PreSignedObjects/PK/Certificate/WindowsOEMDevicesPK.der"
		"https://raw.githubusercontent.com/microsoft/secureboot_objects/main/PreSignedObjects/KEK/Certificates/MicCorKEKCA2011_2011-06-24.der"
		"https://raw.githubusercontent.com/microsoft/secureboot_objects/main/PreSignedObjects/DB/Certificates/MicCorUEFCA2011_2011-06-27.der"
	)

	local cert_names=("pk.der" "kek.der" "db.der")
	local uuid="77fa9abd-0359-4d32-bd60-28f4e78f784b"

	for ((i = 0; i < ${#ms_certs[@]}; i++)); do
		wget -q -O "$temp_dir/${cert_names[$i]}" "${ms_certs[$i]}" 2>/dev/null || true
	done

	if [[ -f "$temp_dir/pk.der" && -f "$temp_dir/kek.der" && -f "$temp_dir/db.der" ]]; then
		$ROOT_ESC virt-fw-vars --input "$vars_file" --output "$vars_file" \
			--set-pk "$uuid" "$temp_dir/pk.der" \
			--add-kek "$uuid" "$temp_dir/kek.der" \
			--add-db "$uuid" "$temp_dir/db.der" &>>"$LOG_FILE" &&
			fmtr::log "Secure Boot certificates injected" ||
			fmtr::warn "Failed to inject Secure Boot certificates"
	else
		fmtr::warn "Could not download Microsoft certificates, skipping injection"
	fi
}

main() {
	fmtr::box_text " Compile EDK2/OVMF Firmware "

	install_req_pkgs "edk2-build"

	if prmt::yes_or_no "$(fmtr::ask 'Download EDK2 source?')"; then
		download_edk2 || exit 1
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Setup EDK2 build environment?')"; then
		setup_edk2_build || exit 1
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Apply EDK2 patches?')"; then
		apply_edk2_patches
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Build OVMF firmware? (takes 10-20 minutes)')"; then
		build_ovmf || exit 1
	fi

	if prmt::yes_or_no "$(fmtr::ask 'Install OVMF?')"; then
		install_ovmf
		inject_secure_boot_certs
		fmtr::log "OVMF installed to: $EDK2_INSTALL_DIR"
	fi

	fmtr::info "OVMF compilation and installation complete!"
}

main
