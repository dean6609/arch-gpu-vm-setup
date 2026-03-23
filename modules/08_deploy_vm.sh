#!/usr/bin/env bash

# =============================================================================
# Module 08: Deploy Windows VM
# Creates and configures the Windows VM with GPU passthrough
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

readonly VM_NAME="WindowsVM"
readonly QEMU_BINARY="${QEMU_INSTALL_DIR:-/opt/gpu-vm-setup/emulator}/bin/qemu-system-x86_64"
readonly OVMF_CODE="${EDK2_INSTALL_DIR:-/opt/gpu-vm-setup/firmware}/OVMF_CODE.fd"
readonly OVMF_VARS="${EDK2_INSTALL_DIR:-/opt/gpu-vm-setup/firmware}/OVMF_VARS.fd"
readonly LIBVIRT_XML="/etc/libvirt/qemu/${VM_NAME}.xml"

load_gpu_config() {
	local config_file="${SCRIPT_DIR}/config.conf"
	if [[ -f "$config_file" ]]; then
		source "$config_file"
	fi
	export GPU_PCI_ADDR GPU_AUDIO_PCI GPU_AUDIO_IDS
}

check_dependencies() {
	fmtr::info "Checking dependencies..."

	if [[ ! -x "$QEMU_BINARY" ]]; then
		fmtr::warn "Custom QEMU not found at $QEMU_BINARY"
		fmtr::info "Will use system qemu-system-x86_64"
	fi

	if [[ ! -f "$OVMF_CODE" ]]; then
		fmtr::warn "OVMF_CODE not found at $OVMF_CODE"
	fi

	if [[ ! -f "$OVMF_VARS" ]]; then
		fmtr::warn "OVMF_VARS not found at $OVMF_VARS"
	fi
}

generate_mac_address() {
	local oui="b0:4e:26"
	local mac="$oui:$(printf '%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))"
	echo "$mac"
}

generate_uuid() {
	uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid
}

generate_disk_serial() {
	tr -dc 'A-F0-9' </dev/urandom | head -c 20
}

select_memory_size() {
	local total_mem_kb total_mem_gb available_gb recommended
	total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
	total_mem_gb=$((total_mem_kb / 1024 / 1024))
	available_gb=$((total_mem_gb - 4))

	if ((available_gb < 8)); then
		available_gb=8
	fi

	local sys_ram
	sys_ram=$(free -h | awk '/^Mem:/{print $2}')

	echo "" >&2
	fmtr::info "System RAM: $sys_ram" >&2
	fmtr::info "Recommendation: leave at least 4GB for host" >&2

	recommended=$available_gb
	if ((recommended > 32)); then
		recommended=32
	elif ((recommended < 8)); then
		recommended=8
	fi

	local options=("8" "12" "16" "24" "32")
	local labels=("8GB - Minimum" "12GB - Standard" "16GB - Recommended" "24GB - High" "32GB - Maximum")

	for ((i = 0; i < ${#options[@]}; i++)); do
		if [[ "${options[$i]}" == "$recommended" ]]; then
			printf '  %d) %s %b(recommended)%b\n' $((i + 1)) "${labels[$i]}" "$TEXT_BRIGHT_GREEN" "$RESET" >&2
		else
			printf '  %d) %s\n' $((i + 1)) "${labels[$i]}" >&2
		fi
	done

	local selection
	read -rp "$(fmtr::ask_inline 'Select memory size: ')" selection >&2

	if ((selection >= 1 && selection <= ${#options[@]})); then
		echo "${options[$((selection - 1))]}"
	else
		echo "$recommended"
	fi
}

select_disk_size() {
	echo "" >&2
	fmtr::info "Select disk size for VM:" >&2

	local options=("60" "100" "250" "500")
	local labels=("60GB - Minimal" "100GB - Standard" "250GB - Large" "500GB - Maximum")

	for ((i = 0; i < ${#options[@]}; i++)); do
		printf '  %d) %s\n' $((i + 1)) "${labels[$i]}" >&2
	done

	local selection
	read -rp "$(fmtr::ask_inline 'Select disk size: ')" selection >&2

	if ((selection >= 1 && selection <= ${#options[@]})); then
		echo "${options[$((selection - 1))]}"
	else
		echo "100"
	fi
}

create_libvirt_xml() {
	local mem_gb="$1"
	local disk_gb="$2"
	local iso_path="$3"

	local cpu_sockets cpu_cores cpu_threads
	cpu_sockets=$(lscpu | awk '/^Socket\(s\):/{print $NF}')
	cpu_cores=$(lscpu | awk '/^Core\(s\) per socket:/{print $NF}')
	cpu_threads=$(lscpu | awk '/^Thread\(s\) per core:/{print $NF}')
	local cpu_vcpus=$((cpu_sockets * cpu_cores * cpu_threads))

	local mac_addr
	mac_addr=$(generate_mac_address)

	local vm_uuid
	vm_uuid=$(generate_uuid)

	local disk_serial
	disk_serial=$(generate_disk_serial)

	local ivshmem_size_mb="${LOOKING_GLASS_SIZE:-32}"
	local qemu_bin="${QEMU_BINARY:-/usr/bin/qemu-system-x86_64}"

	load_gpu_config

	local gpu_pci_domain gpu_pci_bus gpu_pci_slot gpu_pci_func
	local gpu_audio_domain gpu_audio_bus gpu_audio_slot gpu_audio_func

	if [[ -n "$GPU_PCI_ADDR" ]]; then
		gpu_pci_domain=$(echo "$GPU_PCI_ADDR" | cut -d: -f1)
		gpu_pci_bus=$(echo "$GPU_PCI_ADDR" | cut -d: -f2)
		gpu_pci_slot=$(echo "$GPU_PCI_ADDR" | cut -d: -f3 | cut -d. -f1)
		gpu_pci_func=$(echo "$GPU_PCI_ADDR" | cut -d. -f2)
	fi

	if [[ -n "$GPU_AUDIO_PCI" ]]; then
		gpu_audio_domain=$(echo "$GPU_AUDIO_PCI" | cut -d: -f1)
		gpu_audio_bus=$(echo "$GPU_AUDIO_PCI" | cut -d: -f2)
		gpu_audio_slot=$(echo "$GPU_AUDIO_PCI" | cut -d: -f3 | cut -d. -f1)
		gpu_audio_func=$(echo "$GPU_AUDIO_PCI" | cut -d. -f2)
	elif [[ -n "$GPU_PCI_ADDR" ]]; then
		gpu_audio_domain=$gpu_pci_domain
		gpu_audio_bus=$gpu_pci_bus
		gpu_audio_slot=$gpu_pci_slot
		gpu_audio_func="1"
	fi

	local cdrom_section=""
	if [[ -n "$iso_path" && -f "$iso_path" ]]; then
		cdrom_section="
    <disk type=\"file\" device=\"cdrom\">
      <driver name=\"qemu\" type=\"raw\"/>
      <source file=\"$iso_path\"/>
      <target dev=\"sdb\" bus=\"sata\"/>
      <readonly/>
      <boot order=\"1\"/>
    </disk>"
	fi

	local gpu_section=""
	if [[ -n "$GPU_PCI_ADDR" ]]; then
		local rom_section=""
		# Check for VBIOS dump (required for AMD GPUs to fix Error Code 43)
		local vbios_path="/opt/gpu-vm-setup/firmware/rx580.rom"
		if [[ -f "$vbios_path" ]]; then
			rom_section="
      <rom file=\"${vbios_path}\"/>"
		fi
		gpu_section="    <hostdev mode=\"subsystem\" type=\"pci\" managed=\"yes\">
      <driver name=\"vfio\"/>
      <source>
        <address domain=\"0x${gpu_pci_domain}\" bus=\"0x${gpu_pci_bus}\" slot=\"0x${gpu_pci_slot}\" function=\"0x${gpu_pci_func}\"/>
      </source>${rom_section}
    </hostdev>"
	fi

	local gpu_audio_section=""
	if [[ -n "$GPU_AUDIO_PCI" || -n "$GPU_PCI_ADDR" ]]; then
		gpu_audio_section="    <hostdev mode=\"subsystem\" type=\"pci\" managed=\"yes\">
      <source>
        <address domain=\"0x${gpu_audio_domain}\" bus=\"0x${gpu_audio_bus}\" slot=\"0x${gpu_audio_slot}\" function=\"0x${gpu_audio_func}\"/>
      </source>
    </hostdev>"
	fi

	fmtr::info "Generating libvirt XML for VM: $VM_NAME"

	cat >"/tmp/${VM_NAME}.xml" <<EOF
<domain xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0" type="kvm">
  <name>$VM_NAME</name>
  <uuid>$vm_uuid</uuid>
  <memory unit="G">$mem_gb</memory>
  <currentMemory unit="G">$mem_gb</currentMemory>
  <vcpu placement="static">${cpu_vcpus}</vcpu>
  <cpu mode="host-passthrough" check="none" migratable="off">
    <topology sockets="${cpu_sockets}" dies="1" clusters="1" cores="${cpu_cores}" threads="${cpu_threads}"/>
    <cache mode="passthrough"/>
    <maxphysaddr mode="passthrough"/>
$(if [[ "$CPU_VENDOR_ID" == "AuthenticAMD" ]]; then
		echo '    <feature policy="require" name="topoext"/>'
	fi)
    <feature policy="disable" name="hypervisor"/>
    <feature policy="disable" name="ssbd"/>
$(if [[ "$CPU_VENDOR_ID" == "AuthenticAMD" ]]; then
		echo '    <feature policy="disable" name="amd-ssbd"/>'
		echo '    <feature policy="disable" name="virt-ssbd"/>'
	fi)
  </cpu>
  <sysinfo type="smbios">
    <bios>
      <entry name="vendor">American Megatrends International, LLC.</entry>
      <entry name="version">A.80</entry>
      <entry name="date">12/15/2023</entry>
    </bios>
    <system>
      <entry name="manufacturer">Micro-Star International Co., Ltd.</entry>
      <entry name="product">MS-7C91</entry>
      <entry name="version">1.0</entry>
      <entry name="serial">To be filled by O.E.M.</entry>
      <entry name="uuid">$vm_uuid</entry>
      <entry name="sku">To be filled by O.E.M.</entry>
      <entry name="family">To be filled by O.E.M.</entry>
    </system>
    <baseBoard>
      <entry name="manufacturer">Micro-Star International Co., Ltd.</entry>
      <entry name="product">MAG B550 TOMAHAWK (MS-7C91)</entry>
      <entry name="version">1.0</entry>
      <entry name="serial">To be filled by O.E.M.</entry>
    </baseBoard>
    <chassis>
      <entry name="manufacturer">Micro-Star International Co., Ltd.</entry>
      <entry name="version">1.0</entry>
      <entry name="serial">To be filled by O.E.M.</entry>
      <entry name="sku">To be filled by O.E.M.</entry>
    </chassis>
  </sysinfo>
  <os>
    <type arch="x86_64" machine="pc-q35-10.2">hvm</type>
    <smbios mode="sysinfo"/>
    <loader readonly="yes" secure="yes" type="pflash" format="raw">${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.fd}</loader>
    <nvram template="${OVMF_VARS:-/usr/share/edk2/x64/OVMF_VARS.fd}" format="raw"></nvram>
    <bootmenu enable="yes"/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <hyperv mode="custom">
      <relaxed state="on"/>
      <vapic state="on"/>
      <spinlocks state="on" retries="0x1fff"/>
      <vpindex state="on"/>
      <runtime state="off"/>
      <synic state="on"/>
      <stimer state="on"/>
      <reset state="on"/>
      <vendor_id state="on" value="$CPU_VENDOR_ID"/>
      <frequencies state="on"/>
      <reenlightenment state="off"/>
      <tlbflush state="off"/>
      <ipi state="off"/>
      <evmcs state="off"/>
      <avic state="off"/>
      <emsr_bitmap state="off"/>
      <xmm_input state="off"/>
    </hyperv>
    <kvm>
      <hidden state="on"/>
    </kvm>
    <pmu state="off"/>
    <vmport state="off"/>
    <smm state="on"/>
    <msrs unknown="fault"/>
  </features>
  <clock offset="localtime">
    <timer name="tsc" present="yes" mode="native"/>
    <timer name="kvmclock" present="no"/>
    <timer name="hypervclock" present="yes"/>
  </clock>
  <pm>
    <suspend-to-mem enabled="yes"/>
    <suspend-to-disk enabled="yes"/>
  </pm>
  <devices>
    <emulator>$qemu_bin</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="raw" cache="none" io="native" discard="unmap"/>
      <source file="/var/lib/libvirt/images/${VM_NAME}.img"/>
      <target dev="sda" bus="nvme"/>
      <serial>$disk_serial</serial>
      <boot order="2"/>
    </disk>
${cdrom_section}
    <interface type="network">
      <mac address="$mac_addr"/>
      <source network="default"/>
    </interface>
${gpu_section}
${gpu_audio_section}
    <input type="mouse" bus="usb"/>
    <input type="keyboard" bus="usb"/>
    <tpm model="tpm-crb">
      <backend type="emulator" version="2.0"/>
    </tpm>
    <memballoon model="none"/>
    <video>
      <model type="vga"/>
    </video>
    <graphics type="spice" autoport="yes"/>
    <audio id="1" type="spice"/>
    <sound model="ich9">
      <audio id="1"/>
    </sound>
  </devices>
EOF

	if [[ -f "/opt/gpu-vm-setup/firmware/smbios.bin" ]]; then
		cat >>"/tmp/${VM_NAME}.xml" <<EOF
  <qemu:commandline>
    <qemu:arg value="-smbios"/>
    <qemu:arg value="file=/opt/gpu-vm-setup/firmware/smbios.bin"/>
    <qemu:arg value="-object"/>
    <qemu:arg value="memory-backend-file,id=looking-glass,mem-path=/dev/shm/looking-glass,size=$((ivshmem_size_mb * 1024 * 1024)),share=on"/>
    <qemu:arg value="-device"/>
    <qemu:arg value="ivshmem-plain,id=shmem0,memdev=looking-glass,bus=pcie.0,addr=0x10"/>
  </qemu:commandline>
</domain>
EOF
	else
		cat >>"/tmp/${VM_NAME}.xml" <<EOF
  <qemu:commandline>
    <qemu:arg value="-object"/>
    <qemu:arg value="memory-backend-file,id=looking-glass,mem-path=/dev/shm/looking-glass,size=$((ivshmem_size_mb * 1024 * 1024)),share=on"/>
    <qemu:arg value="-device"/>
    <qemu:arg value="ivshmem-plain,id=shmem0,memdev=looking-glass,bus=pcie.0,addr=0x10"/>
  </qemu:commandline>
</domain>
EOF
	fi

	fmtr::log "Generated XML: /tmp/${VM_NAME}.xml"
}

create_vm_disk() {
	local disk_gb="$1"
	local disk_path="/var/lib/libvirt/images/${VM_NAME}.img"

	fmtr::info "Creating VM disk (${disk_gb}GB)..."

	if [[ -f "$disk_path" ]]; then
		fmtr::warn "Disk already exists at $disk_path"
		if prmt::yes_or_no "$(fmtr::ask 'Overwrite existing disk?')"; then
			$ROOT_ESC rm -f "$disk_path"
		else
			fmtr::info "Using existing disk"
			return 0
		fi
	fi

	$ROOT_ESC mkdir -p /var/lib/libvirt/images
	$ROOT_ESC truncate -s "${disk_gb}G" "$disk_path" ||
		{
			fmtr::error "Failed to create disk"
			return 1
		}

	fmtr::log "Created disk: $disk_path"
}

define_vm() {
	fmtr::info "Defining VM in libvirt..."

	if $ROOT_ESC virsh dominfo "$VM_NAME" &>/dev/null; then
		$ROOT_ESC virsh destroy "$VM_NAME" &>/dev/null || true
		$ROOT_ESC virsh undefine "$VM_NAME" --nvram &>/dev/null
		fmtr::log "Removed existing VM: $VM_NAME"
	fi

	if $ROOT_ESC virsh define /tmp/${VM_NAME}.xml &>>"$LOG_FILE"; then
		fmtr::log "VM defined successfully"
	else
		fmtr::error "Failed to define VM"
		return 1
	fi

	fmtr::info "VM defined. To start: sudo virsh start $VM_NAME"
	fmtr::info "To view console: virt-viewer $VM_NAME"
	fmtr::info "Or open virt-manager for graphical access"
}

show_vm_info() {
	fmtr::info "VM Configuration Complete!"
	echo ""
	echo "  VM Name: $VM_NAME"
	echo "  XML Config: $LIBVIRT_XML"
	echo "  Disk: /var/lib/libvirt/images/${VM_NAME}.img"
	echo ""
	echo "Next steps:"
	echo "  1. Start VM: virsh start $VM_NAME"
	echo "  2. Connect via VNC or Looking Glass"
	echo "  3. Install Windows from ISO"
	echo "  4. Install NVIDIA drivers in Windows"
	echo ""
}

download_with_fido() {
	local win_ver="$1"
	local output_path="$2"

	if ! command -v pwsh &>/dev/null; then
		fmtr::warn "PowerShell not installed" >&2
		if prmt::yes_or_no "$(fmtr::ask_inline 'Install PowerShell now? [y/n]: ')" >&2; then
			$ROOT_ESC pacman -S --noconfirm powershell 2>&1 | tee -a "$LOG_FILE" || return 1
		else
			return 1
		fi
	fi

	fmtr::info "Downloading Windows $win_ver using Fido..." >&2

	local fido_url="https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1"
	curl -fsSL "$fido_url" -o /tmp/Fido.ps1 || return 1

	pwsh -NonInteractive -Command "& /tmp/Fido.ps1 -Win $win_ver -Lang English -Arch x64 -DownloadPath '$output_path'" 2>&1 | tee -a "$LOG_FILE" || return 1

	[[ -f "$output_path" ]]
}

download_with_aria2c() {
	local url="$1"
	local output_path="$2"

	fmtr::info "Downloading with aria2c..." >&2

	if command -v aria2c &>/dev/null; then
		aria2c -x16 -s16 -d "$(dirname "$output_path")" -o "$(basename "$output_path")" "$url" 2>&1 | tee -a "$LOG_FILE"
	else
		curl -L --progress-bar -o "$output_path" "$url" 2>&1 | tee -a "$LOG_FILE"
	fi
}

validate_iso() {
	local iso_path="$1"

	if [[ ! -f "$iso_path" ]]; then
		fmtr::error "ISO file not found: $iso_path" >&2
		return 1
	fi

	local file_size
	file_size=$(stat -c%s "$iso_path" 2>/dev/null || stat -f%z "$iso_path" 2>/dev/null)

	if ((file_size < 3000000000)); then
		fmtr::error "ISO file too small (${file_size} bytes), expected at least 3GB" >&2
		return 1
	fi

	if ! file "$iso_path" | grep -qi "ISO 9660\|UDF"; then
		fmtr::warn "ISO format may not be valid" >&2
	fi

	local sha256
	sha256=$(sha256sum "$iso_path" 2>/dev/null | cut -d' ' -f1 || shasum -a256 "$iso_path" 2>/dev/null | cut -d' ' -f1)
	fmtr::info "SHA256: $sha256" >&2

	return 0
}

download_win10_ltsc() {
	local download_path="$HOME/Downloads/win10ltsc.iso"

	if [[ -f "$download_path" ]]; then
		fmtr::warn "Windows 10 LTSC ISO already exists at $download_path" >&2
		if prmt::yes_or_no "$(fmtr::ask_inline 'Use existing file? [y/n]: ')" >&2; then
			if validate_iso "$download_path"; then
				echo "$download_path"
				return 0
			fi
		fi
	fi

	fmtr::info "Downloading Windows 10 IoT Enterprise LTSC 2021..." >&2

	local url="https://software-download.microsoft.com/download/sg/19044.1288.211006-0501.21h2_release_svc_refresh_CLIENT_LTSC_EVAL_x64FRE_en-us.iso"

	download_with_aria2c "$url" "$download_path" || return 1

	if validate_iso "$download_path"; then
		echo "$download_path"
	else
		fmtr::error "Direct download failed. Please download manually from:" >&2
		fmtr::info "https://www.microsoft.com/en-us/evalcenter/download-windows-10-iot" >&2
		fmtr::info "Filename: en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso" >&2
		read -rp "Enter path to downloaded ISO: " download_path >&2
		if validate_iso "$download_path"; then
			echo "$download_path"
		else
			return 1
		fi
	fi
}

download_windows_iso() {
	local win_ver="$1"
	local download_path=""

	case "$win_ver" in
	win10)
		download_path="$HOME/Downloads/win10.iso"
		;;
	win11)
		download_path="$HOME/Downloads/win11.iso"
		;;
	esac

	if [[ -f "$download_path" ]]; then
		fmtr::warn "Windows $win_ver ISO already exists at $download_path" >&2
		if prmt::yes_or_no "$(fmtr::ask_inline 'Use existing file? [y/n]: ')" >&2; then
			if validate_iso "$download_path"; then
				echo "$download_path"
				return 0
			fi
		fi
	fi

	fmtr::info "Attempting download with Fido..." >&2
	if download_with_fido "$win_ver" "$download_path"; then
		if validate_iso "$download_path"; then
			echo "$download_path"
			return 0
		fi
	fi

	fmtr::warn "Fido download failed or not available" >&2

	read -rp "Enter path to Windows ISO file: " iso_input >&2

	if [[ -f "$iso_input" ]] && validate_iso "$iso_input"; then
		echo "$iso_input"
		return 0
	fi

	return 1
}

select_windows_iso() {
	local iso_path=""
	local osinfo=""

	echo "" >&2
	fmtr::info "Select Windows installation source:" >&2
	echo "  1) Windows 10          - Auto-download via Fido or custom ISO path" >&2
	echo "  2) Windows 10 LTSC     - Direct download (no registration required)" >&2
	echo "  3) Windows 11          - Auto-download via Fido or custom ISO path" >&2
	echo "  4) Custom ISO          - Enter path manually" >&2

	local selection
	read -rp "$(fmtr::ask_inline 'Selection [1-4]: ')" selection >&2

	case "$selection" in
	1)
		iso_path=$(download_windows_iso "win10")
		osinfo="win10"
		;;
	2)
		iso_path=$(download_win10_ltsc)
		osinfo="win10"
		;;
	3)
		iso_path=$(download_windows_iso "win11")
		osinfo="win11"
		;;
	4)
		echo "" >&2
		read -rp "Enter full path to ISO file: " iso_path >&2
		if [[ -f "$iso_path" ]]; then
			if ! validate_iso "$iso_path"; then
				fmtr::error "Invalid ISO file" >&2
				iso_path=""
			else
				if echo "$iso_path" | grep -qi "11"; then
					osinfo="win11"
				else
					osinfo="win10"
				fi
			fi
		else
			fmtr::error "File not found: $iso_path" >&2
			iso_path=""
		fi
		;;
	*)
		fmtr::error "Invalid selection" >&2
		iso_path=""
		;;
	esac

	if [[ -n "$iso_path" && -f "$iso_path" ]]; then
		fmtr::log "Using ISO: $iso_path" >&2
	fi

	echo "$iso_path"
}

main() {
	fmtr::box_text " Deploy Windows VM "

	check_dependencies
	load_gpu_config

	if [[ -z "$GPU_PCI_ADDR" ]]; then
		fmtr::warn "No GPU configured for passthrough"
	fi

	local iso_path
	iso_path=$(select_windows_iso)

	local mem_gb
	mem_gb=$(select_memory_size)

	local disk_gb
	disk_gb=$(select_disk_size)

	if virsh dominfo "$VM_NAME" &>/dev/null; then
		fmtr::warn "VM $VM_NAME already exists"
		if prmt::yes_or_no "$(fmtr::ask 'Undefine and recreate VM?')"; then
			virsh shutdown "$VM_NAME" &>/dev/null || true
			virsh destroy "$VM_NAME" &>/dev/null || true
			virsh undefine "$VM_NAME" --nvram &>>"$LOG_FILE"
			fmtr::log "Removed existing VM definition"
		else
			fmtr::info "Using existing VM configuration"
			return 0
		fi
	fi

	create_vm_disk "$disk_gb"

	create_libvirt_xml "$mem_gb" "$disk_gb" "$iso_path"

	define_vm

	show_vm_info
}

main
