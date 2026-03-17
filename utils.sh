#!/usr/bin/env bash

# =============================================================================
# GPU VM Setup - Utilities Module
# Provides logging, prompts, package installation, and system detection
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# =============================================================================
# ANSI ESCAPE CODES - Text Styles, Colors, Backgrounds
# =============================================================================

readonly RESET=$'\033[0m'
readonly TEXT_BOLD=$'\033[1m'
readonly TEXT_DIM=$'\033[2m'
readonly TEXT_ITALIC=$'\033[3m'
readonly TEXT_UNDER=$'\033[4m'
readonly TEXT_BLINK=$'\033[5m'
readonly TEXT_REVERSE=$'\033[7m'
readonly TEXT_HIDDEN=$'\033[8m'
readonly TEXT_STRIKE=$'\033[9m'

readonly TEXT_BLACK=$'\033[30m' TEXT_GRAY=$'\033[90m'
readonly TEXT_RED=$'\033[31m' TEXT_BRIGHT_RED=$'\033[91m'
readonly TEXT_GREEN=$'\033[32m' TEXT_BRIGHT_GREEN=$'\033[92m'
readonly TEXT_YELLOW=$'\033[33m' TEXT_BRIGHT_YELLOW=$'\033[93m'
readonly TEXT_BLUE=$'\033[34m' TEXT_BRIGHT_BLUE=$'\033[94m'
readonly TEXT_MAGENTA=$'\033[35m' TEXT_BRIGHT_MAGENTA=$'\033[95m'
readonly TEXT_CYAN=$'\033[36m' TEXT_BRIGHT_CYAN=$'\033[96m'
readonly TEXT_WHITE=$'\033[37m' TEXT_BRIGHT_WHITE=$'\033[97m'

readonly BACK_BLACK=$'\033[40m' BACK_GRAY=$'\033[100m'
readonly BACK_RED=$'\033[41m' BACK_BRIGHT_RED=$'\033[101m'
readonly BACK_GREEN=$'\033[42m' BACK_BRIGHT_GREEN=$'\033[102m'
readonly BACK_YELLOW=$'\033[43m' BACK_BRIGHT_YELLOW=$'\033[103m'
readonly BACK_BLUE=$'\033[44m' BACK_BRIGHT_BLUE=$'\033[104m'
readonly BACK_MAGENTA=$'\033[45m' BACK_BRIGHT_MAGENTA=$'\033[105m'
readonly BACK_CYAN=$'\033[46m' BACK_BRIGHT_CYAN=$'\033[106m'
readonly BACK_WHITE=$'\033[47m' BACK_BRIGHT_WHITE=$'\033[107m'

# =============================================================================
# LOGGING (low-level)
# =============================================================================

__log::write() {
	local stream=$1
	shift
	if [[ $stream == stderr ]]; then
		printf '%b\n' "$*" >&2
	else
		printf '%b\n' "$*"
	fi
	printf '%b\n' "$*" >>"$LOG_FILE"
}

# =============================================================================
# FORMAT / LOG HELPERS
# =============================================================================

__fmtr::line() {
	local icon=$1 color=$2
	shift 2
	printf '\n  %b%s%b %s' "$color" "$icon" "$RESET" "$*"
}

fmtr::log() { __log::write stdout "$(__fmtr::line '[+]' "$TEXT_BRIGHT_GREEN" "$@")"; }
fmtr::info() { __log::write stdout "$(__fmtr::line '[i]' "$TEXT_BRIGHT_CYAN" "$@")"; }
fmtr::warn() { __log::write stdout "$(__fmtr::line '[!]' "$TEXT_BRIGHT_YELLOW" "$@")"; }
fmtr::error() { __log::write stderr "$(__fmtr::line '[-]' "$TEXT_BRIGHT_RED" "$@")"; }

fmtr::fatal() {
	__log::write stderr "$(printf '\n  %b%s %s%b' "$TEXT_RED$TEXT_BOLD" '[X]' "$*" "$RESET")"
}

fmtr::box_text() {
	local text=$1 pad border
	printf -v pad '%*s' $((${#text} + 2)) ''
	border=${pad// /═}
	printf '\n  ╔%s╗\n  ║ %s ║\n  ╚%s╝\n' "$border" "$text" "$border"
}

fmtr::ask() {
	__log::write stdout "$(printf '\n  %b[?]%b %s' "$TEXT_BLACK$BACK_BRIGHT_GREEN" "$RESET" "$1")"
}

fmtr::ask_inline() {
	printf '\n  %b[?]%b %s' "$TEXT_BLACK$BACK_BRIGHT_GREEN" "$RESET" "$1"
}

# =============================================================================
# PROMPTS
# =============================================================================

prmt::yes_or_no() {
	local prompt=$* ans
	while :; do
		read -rp "$prompt [y/n]: " ans
		printf '%s\n' "$ans" >>"$LOG_FILE"
		case ${ans,,} in
		y*) return 0 ;;
		n*) return 1 ;;
		*) printf '\n  [!] Please answer y/n\n' ;;
		esac
	done
}

prmt::quick_prompt() {
	local response
	read -n1 -srp "$1" response
	printf '%s\n' "$response"
	printf '%s\n' "$response" >>"$LOG_FILE"
}

# =============================================================================
# DEBUG
# =============================================================================

dbg::fail() {
	fmtr::fatal "$1"
	exit 1
}

# =============================================================================
# COMPATIBILITY
# =============================================================================

compat::get_escalation_cmd() {
	local cmd
	for cmd in sudo doas pkexec; do
		if command -v -- "$cmd" &>/dev/null; then
			ROOT_ESC=$cmd
			export ROOT_ESC
			return 0
		fi
	done

	fmtr::error "No supported privilege escalation tool found (sudo/doas/pkexec)."
	exit 1
}

# =============================================================================
# PACKAGES
# =============================================================================

install_req_pkgs() {
	local component=$1
	[[ -n $component ]] || {
		fmtr::error "Component name not specified!"
		exit 1
	}

	fmtr::log "Checking for required missing $component packages..."

	local mgr install_flags check_cmd
	case $DISTRO in
	Arch)
		mgr=pacman
		install_flags='-S --noconfirm'
		check_cmd='pacman -Q'
		;;
	Debian)
		mgr=apt
		install_flags='-y install'
		check_cmd='dpkg -s'
		;;
	openSUSE)
		mgr=zypper
		install_flags='install -y'
		check_cmd='rpm -q'
		;;
	Fedora)
		mgr=dnf
		install_flags='-y install'
		check_cmd='rpm -q'
		;;
	*)
		fmtr::error "Unsupported distribution: $DISTRO."
		exit 1
		;;
	esac

	local pkg_var="REQUIRED_PKGS_${DISTRO}"
	declare -n req="$pkg_var" 2>/dev/null || {
		fmtr::error "$component packages undefined for $DISTRO."
		exit 1
	}

	local -a missing=()
	local pkg
	for pkg in "${req[@]}"; do
		$check_cmd "$pkg" &>/dev/null || missing+=("$pkg")
	done

	((${#missing[@]})) || {
		fmtr::log "All required $component packages already installed."
		return 0
	}

	fmtr::warn "Missing required $component packages: ${missing[*]}"
	if prmt::yes_or_no "$(fmtr::ask_inline "Install required missing $component packages?")"; then
		$ROOT_ESC "$mgr" $install_flags "${missing[@]}" &>>"$LOG_FILE" || {
			fmtr::error "Failed to install required $component packages"
			exit 1
		}
		fmtr::log "Installed: ${missing[*]}"
	else
		fmtr::log "Exiting due to required missing $component packages."
		exit 1
	fi
}

# =============================================================================
# LOGGING (init / side-effects)
# =============================================================================

log::init() {
	: "${LOG_PATH:=${SCRIPT_DIR}/logs}"
	: "${LOG_FILE:=$LOG_PATH/$(date +%s).log}"

	export LOG_PATH LOG_FILE
	mkdir -p -- "$LOG_PATH" || {
		printf 'Failed to create log directory.\n' >&2
		exit 1
	}
	: >"$LOG_FILE" || {
		printf 'Failed to create log file.\n' >&2
		exit 1
	}
}

# =============================================================================
# SYSTEM DETECTION
# =============================================================================

detect_distro() {
	local id

	if [[ -r /etc/os-release ]]; then
		. /etc/os-release
		id=${ID,,}
	fi

	case "$id" in
	arch | manjaro | endeavouros | arcolinux | garuda | artix) DISTRO="Arch" ;;
	opensuse-* | sles) DISTRO="openSUSE" ;;
	debian | ubuntu | linuxmint | kali | pureos | pop | elementary | zorin | mx | parrot | deepin | peppermint | trisquel | bodhi | linuxlite | neon) DISTRO="Debian" ;;
	fedora | centos | rhel | rocky | alma | oracle) DISTRO="Fedora" ;;
	*)
		if command -v pacman >/dev/null 2>&1; then
			DISTRO="Arch"
		elif command -v apt >/dev/null 2>&1; then
			DISTRO="Debian"
		elif command -v zypper >/dev/null 2>&1; then
			DISTRO="openSUSE"
		elif command -v dnf >/dev/null 2>&1; then
			DISTRO="Fedora"
		else
			fmtr::fatal "${id:-Unknown} distro isn't supported yet."
		fi
		;;
	esac

	export DISTRO
	readonly DISTRO
}

cpu_detect() {
	local vendor
	vendor=$(awk -F': +' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)

	[[ -n $vendor ]] || fmtr::fatal "Unable to determine CPU vendor from /proc/cpuinfo"

	case "$vendor" in
	*AuthenticAMD*)
		CPU_VENDOR_ID="AuthenticAMD"
		CPU_VIRTUALIZATION="svm"
		CPU_MANUFACTURER="AMD"
		;;
	*GenuineIntel*)
		CPU_VENDOR_ID="GenuineIntel"
		CPU_VIRTUALIZATION="vmx"
		CPU_MANUFACTURER="Intel"
		;;
	*)
		fmtr::fatal "Unsupported CPU vendor: $vendor"
		;;
	esac

	export CPU_VENDOR_ID CPU_VIRTUALIZATION CPU_MANUFACTURER
	readonly CPU_VENDOR_ID CPU_VIRTUALIZATION CPU_MANUFACTURER
}

detect_bootloader() {
	if [[ -f /etc/default/limine ]]; then
		BOOTLOADER_TYPE="limine"
		BOOTLOADER_CONFIG="/etc/default/limine"
		return 0
	fi

	if [[ -f /etc/default/grub ]]; then
		BOOTLOADER_TYPE="grub"
		BOOTLOADER_CONFIG="/etc/default/grub"
		return 0
	fi

	local -a sdbot_dirs=("/boot/loader/entries" "/boot/efi/loader/entries" "/efi/loader/entries")
	for dir in "${sdbot_dirs[@]}"; do
		if [[ -d "$dir" ]]; then
			BOOTLOADER_TYPE="systemd-boot"
			BOOTLOADER_CONFIG=$(find "$dir" -maxdepth 1 -type f -name '*.conf' ! -name '*-fallback.conf' -print -quit)
			[[ -n "$BOOTLOADER_CONFIG" ]] && return 0
		fi
	done

	fmtr::error "No supported bootloader detected (Limine, GRUB, or systemd-boot)."
	return 1
}

# =============================================================================
# BACKUP FUNCTIONS
# =============================================================================

create_backup() {
	local backup_dir="/var/backups/gpu-vm-setup"
	local timestamp=$(date +%Y%m%d-%H%M%S)
	local backup_path="$backup_dir/setup-$timestamp"

	$ROOT_ESC mkdir -p "$backup_path"

	local files_to_backup=(
		"/etc/modprobe.d/vfio.conf"
		"/etc/modprobe.d/blacklist-gpu-passthrough.conf"
		"/etc/default/grub"
		"/etc/default/limine"
		"/etc/environment"
		"/etc/mkinitcpio.conf"
	)

	for file in "${files_to_backup[@]}"; do
		if [[ -f "$file" ]]; then
			$ROOT_ESC cp -v "$file" "$backup_path/" 2>>"$LOG_FILE"
		fi
	done

	fmtr::log "Backup created at: $backup_path"
	echo "$backup_path"
}

# =============================================================================
# GPU DETECTION
# =============================================================================

detect_gpus() {
	local -a gpus=()
	local -A lspci_map=()

	while IFS= read -r line; do
		lspci_map["${line%% *}"]="$line"
	done < <(lspci -D 2>/dev/null)

	for dev in /sys/bus/pci/devices/*; do
		read -r dev_class <"$dev/class" 2>/dev/null || continue
		[[ $dev_class == 0x03* ]] || continue

		local bdf=${dev##*/}
		local desc=${lspci_map[$bdf]:-}
		[[ -n "$desc" ]] || continue
		desc=${desc##*[}
		desc=${desc%%]*}

		local vendor_id device_id
		vendor_id=$(cat "$dev/vendor" 2>/dev/null)
		device_id=$(cat "$dev/device" 2>/dev/null)

		local driver=""
		if [[ -L "$dev/driver" ]]; then
			driver=$(basename "$(readlink "$dev/driver")")
		fi

		gpus+=("$bdf|$vendor_id|$device_id|$desc|$driver")
	done

	printf '%s\n' "${gpus[@]}"
}

get_gpu_type() {
	local pci_addr="$1"
	local -a integrated=("0x1002" "0x8086")

	local vendor
	vendor=$(cat "/sys/bus/pci/devices/$pci_addr/vendor" 2>/dev/null)
	vendor=${vendor#0x}

	for int_vendor in "${integrated[@]}"; do
		if [[ "$vendor" == "${int_vendor#0x}" ]]; then
			echo "integrated"
			return
		fi
	done

	echo "dedicated"
}

get_gpu_driver() {
	local pci_addr="$1"
	local driver=""

	if [[ -L "/sys/bus/pci/devices/$pci_addr/driver" ]]; then
		driver=$(basename "$(readlink "/sys/bus/pci/devices/$pci_addr/driver")")
	fi

	echo "$driver"
}

get_iommu_group() {
	local pci_addr="$1"
	local group_path

	group_path=$(readlink -f "/sys/bus/pci/devices/$pci_addr/iommu_group" 2>/dev/null) || return

	echo "${group_path##*/}"
}

get_iommu_group_devices() {
	local group_num="$1"
	local devices=()

	for dev in "/sys/kernel/iommu_groups/$group_num/devices/"*; do
		[[ -e "$dev" ]] || continue
		devices+=("${dev##*/}")
	done

	printf '%s\n' "${devices[@]}"
}

# =============================================================================
# CONFIGURATION FILE MANAGEMENT
# =============================================================================

read_config() {
	local config_file="${SCRIPT_DIR}/config.conf"

	if [[ -f "$config_file" ]]; then
		source "$config_file"
	fi

	export GPU_PCI_ADDR GPU_VENDOR_ID GPU_DEVICE_ID GPU_NAME GPU_DRIVER_ORIGINAL
	export GPU_AUDIO_PCI GPU_AUDIO_IDS GPU_IOMMU_GROUP
}

write_config() {
	local config_file="${SCRIPT_DIR}/config.conf"

	{
		echo "# GPU VM Setup Configuration"
		echo "# Generated: $(date)"
		echo ""
		echo "GPU_PCI_ADDR=\"${GPU_PCI_ADDR:-}\""
		echo "GPU_VENDOR_ID=\"${GPU_VENDOR_ID:-}\""
		echo "GPU_DEVICE_ID=\"${GPU_DEVICE_ID:-}\""
		echo "GPU_NAME=\"${GPU_NAME:-}\""
		echo "GPU_DRIVER_ORIGINAL=\"${GPU_DRIVER_ORIGINAL:-}\""
		echo "GPU_AUDIO_PCI=\"${GPU_AUDIO_PCI:-}\""
		echo "GPU_AUDIO_IDS=\"${GPU_AUDIO_IDS:-}\""
		echo "GPU_IOMMU_GROUP=\"${GPU_IOMMU_GROUP:-}\""
		echo "LOOKING_GLASS_SIZE=\"${LOOKING_GLASS_SIZE:-32}\""
	} >"$config_file"

	fmtr::log "Configuration saved to: $config_file"
}

# =============================================================================
# AUTO-INIT (when sourced/executed)
# =============================================================================

log::init
compat::get_escalation_cmd
detect_distro
cpu_detect
read_config
