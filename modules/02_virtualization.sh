#!/usr/bin/env bash

# =============================================================================
# Module 02: Virtualization Setup
# Installs QEMU/KVM, libvirt, and related packages
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

REQUIRED_PKGS_Arch=(
	qemu-full
	edk2-ovmf
	libvirt
	dnsmasq
	virt-manager
	swtpm
	dmidecode
	acpica
)

REQUIRED_PKGS_Debian=(
	qemu-system-x86
	ovmf
	virt-manager
	libvirt-clients
	swtpm
	libvirt-daemon-system
	libvirt-daemon-config-network
	dmidecode
	acpica
)

REQUIRED_PKGS_openSUSE=(
	libvirt
	libvirt-client
	libvirt-daemon
	virt-manager
	qemu
	qemu-kvm
	ovmf
	qemu-tools
	swtpm
	dmidecode
)

REQUIRED_PKGS_Fedora=(
	@virtualization
	swtpm
	dmidecode
	edk2-ovmf
)

configure_user_groups() {
	local target_user="${SUDO_USER:-$USER}"
	local user_groups=" $(id -nG "$target_user") "

	fmtr::info "Configuring user groups for $target_user..."

	for grp in input kvm libvirt; do
		if [[ "$user_groups" == *" $grp "* ]]; then
			fmtr::log "User $target_user already in $grp group"
		else
			$ROOT_ESC usermod -aG "$grp" "$target_user"
			fmtr::log "Added $target_user to $grp group"
		fi
	done
}

configure_libvirt_network() {
	fmtr::info "Configuring libvirt default network..."

	local xml_path="/etc/libvirt/qemu/networks/default.xml"

	if [[ -f "$xml_path" ]]; then
		local OUI="b0:4e:26"
		local RANDOM_MAC="$OUI:$(printf '%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))"

		$ROOT_ESC sed -i \
			-e "s|<mac address='[0-9A-Fa-f:]\{17\}'|<mac address='$RANDOM_MAC'|g" \
			-e "s|address='[0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}'|address='10.0.0.1'|g" \
			-e "s|start='[0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}'|start='10.0.0.2'|g" \
			-e "s|end='[0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}'|end='10.0.0.254'|g" \
			"$xml_path" 2>>"$LOG_FILE"

		fmtr::log "Modified libvirt network MAC and IP range"
	else
		fmtr::warn "Libvirt network XML not found at $xml_path"
	fi
}

enable_libvirt_services() {
	fmtr::info "Enabling libvirt services..."

	$ROOT_ESC systemctl enable --now libvirtd.socket &>>"$LOG_FILE" &&
		fmtr::log "Enabled libvirtd.socket" ||
		fmtr::warn "Failed to enable libvirtd.socket"

	$ROOT_ESC systemctl enable --now virtlogd.socket &>>"$LOG_FILE" &&
		fmtr::log "Enabled virtlogd.socket" ||
		fmtr::warn "Failed to enable virtlogd.socket"

	$ROOT_ESC virsh net-autostart default &>>"$LOG_FILE" || true

	local net_state
	net_state=$($ROOT_ESC virsh net-info default 2>>"$LOG_FILE" | awk '/^Active:/{print $2}')

	if [[ "$net_state" == "yes" ]]; then
		fmtr::log "Default libvirt network already active"
	else
		$ROOT_ESC virsh net-start default &>>"$LOG_FILE" &&
			fmtr::log "Started default libvirt network" ||
			fmtr::warn "Failed to start default network"
	fi
}

main() {
	fmtr::box_text " Virtualization Setup "

	install_req_pkgs "virtualization"

	configure_user_groups

	if prmt::yes_or_no "$(fmtr::ask 'Configure libvirt network with custom MAC and IP range?')"; then
		configure_libvirt_network
	fi

	enable_libvirt_services

	fmtr::warn "Logout and login (or reboot) for group membership changes to take effect."
	fmtr::info "Run 'newgrp kvm' to apply groups without logging out."
}

main
