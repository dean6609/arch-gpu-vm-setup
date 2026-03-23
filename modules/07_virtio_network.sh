#!/usr/bin/env bash

# =============================================================================
# Module: VirtIO Network Driver
# Downloads virtio-win.iso and switches VM NIC to paravirtualized virtio
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/utils.sh" || {
	echo "Failed to load utilities module!"
	exit 1
}

export LIBVIRT_DEFAULT_URI="qemu:///system"

VIRTIO_ISO_DIR="${SCRIPT_DIR}/firmware"
VIRTIO_ISO_PATH="${VIRTIO_ISO_DIR}/virtio-win.iso"
VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
VM_NAME="WindowsVM"

fmtr::box_text " VirtIO Network Driver Setup "

echo ""
fmtr::info "This module installs the VirtIO paravirtualized network driver"
fmtr::info "for your Windows VM, replacing the emulated RTL8139 adapter."
echo ""
fmtr::info "Benefits:"
fmtr::info "  - Full 1Gbps throughput (RTL8139 caps at ~200Mbps)"
fmtr::info "  - Lower CPU overhead and latency"
fmtr::info "  - Better interrupt handling and multi-queue support"
echo ""
fmtr::warn "IMPORTANT - Anti-Cheat Considerations:"
fmtr::warn "  The VirtIO driver exposes paravirtualization signatures that"
fmtr::warn "  some anti-cheat systems (EAC, BattlEye, Vanguard) may detect"
fmtr::warn "  as a virtual machine environment. Games with strict VM"
fmtr::warn "  restrictions may refuse to launch or flag your session."
fmtr::warn "  This is recommended only AFTER your system is fully installed"
fmtr::warn "  and you want to improve network performance."
echo ""
fmtr::info "What will happen:"
fmtr::info "  1. Download virtio-win.iso (~600MB) via aria2c"
fmtr::info "  2. Save to: ${VIRTIO_ISO_PATH}"
fmtr::info "  3. Attach as CDROM to the VM"
fmtr::info "  4. Switch NIC model from RTL8139 to VirtIO"
fmtr::info "  5. You will need to install the driver inside Windows"
echo ""

if ! prmt::yes_or_no "$(fmtr::ask 'Proceed with VirtIO network driver setup?')"; then
	fmtr::log "Cancelled by user"
	exit 0
fi

# Check VM exists and is shut off
vm_state=$(virsh domstate "$VM_NAME" 2>/dev/null)
if [[ "$vm_state" == "" ]]; then
	fmtr::error "VM '$VM_NAME' not found. Deploy the VM first (option 8)."
	exit 1
fi
if [[ "$vm_state" != "shut off" ]]; then
	fmtr::error "VM must be shut off first. Current state: $vm_state"
	exit 1
fi

# Step 1: Download virtio-win.iso
fmtr::info "Step 1: Downloading virtio-win.iso..."
mkdir -p "$VIRTIO_ISO_DIR"

if [[ -f "$VIRTIO_ISO_PATH" ]]; then
	fmtr::log "virtio-win.iso already exists ($(du -h "$VIRTIO_ISO_PATH" | cut -f1))"
	if ! prmt::yes_or_no "$(fmtr::ask 'Re-download?')"; then
		fmtr::info "Using existing ISO"
	else
		aria2c -d "$VIRTIO_ISO_DIR" -o virtio-win.iso "$VIRTIO_ISO_URL" 2>&1 | tail -3
	fi
else
	aria2c -d "$VIRTIO_ISO_DIR" -o virtio-win.iso "$VIRTIO_ISO_URL" 2>&1 | tail -3
fi

if [[ ! -f "$VIRTIO_ISO_PATH" ]]; then
	fmtr::error "Download failed. Check your internet connection."
	exit 1
fi
fmtr::log "ISO ready: $VIRTIO_ISO_PATH ($(du -h "$VIRTIO_ISO_PATH" | cut -f1))"

# Step 2: Attach ISO as CDROM
fmtr::info "Step 2: Attaching ISO to VM..."

# Remove any existing virtio-win CDROM
virsh dumpxml "$VM_NAME" >/tmp/vm_virtio_setup.xml
sed -i '/virtio-win\.iso/,/<\/disk>/d' /tmp/vm_virtio_setup.xml
virsh define /tmp/vm_virtio_setup.xml &>/dev/null

cat >/tmp/virtio_cdrom.xml <<XMLEOF
<disk type='file' device='cdrom'>
  <driver name='qemu' type='raw'/>
  <source file='${VIRTIO_ISO_PATH}'/>
  <target dev='sdc' bus='sata'/>
  <readonly/>
</disk>
XMLEOF

if virsh attach-device "$VM_NAME" /tmp/virtio_cdrom.xml --config &>/dev/null; then
	fmtr::log "ISO attached as CDROM (sdc)"
else
	fmtr::error "Failed to attach ISO"
	exit 1
fi

# Step 3: Switch NIC to virtio
fmtr::info "Step 3: Switching NIC from RTL8139 to VirtIO..."

virsh dumpxml "$VM_NAME" >/tmp/vm_virtio_setup.xml
current_model=$(grep -o "model type='[^']*'" /tmp/vm_virtio_setup.xml | head -1 | grep -o "'[^']*'" | tr -d "'")

if [[ "$current_model" == "virtio" ]]; then
	fmtr::log "NIC already using VirtIO model"
else
	sed -i "s/<model type='${current_model}'\/>/<model type='virtio'\/>/" /tmp/vm_virtio_setup.xml
	if virsh define /tmp/vm_virtio_setup.xml &>/dev/null; then
		fmtr::log "NIC switched: ${current_model} -> virtio"
	else
		fmtr::error "Failed to update VM NIC"
		exit 1
	fi
fi

rm -f /tmp/vm_virtio_setup.xml /tmp/virtio_cdrom.xml

# Summary
echo ""
fmtr::box_text " Setup Complete "
echo ""
fmtr::log "VirtIO network driver configured successfully"
echo ""
fmtr::info "Next steps inside Windows:"
fmtr::info "  1. Start the VM (Gaming Mode or ./gaming-mode.sh)"
fmtr::info "  2. Open Device Manager (Win+X -> Device Manager)"
fmtr::info "  3. Find the unrecognized network adapter"
fmtr::info "  4. Right-click -> Update driver -> Browse my computer"
fmtr::info "  5. Browse to the CDROM drive (virtio-win)"
fmtr::info "  6. Navigate to: NetKVM\\w11\\amd64\\"
fmtr::info "  7. Click Next -> Install the driver"
fmtr::info "  8. Network will come up at full 1Gbps"
echo ""
fmtr::info "The ISO is permanently stored at:"
fmtr::info "  ${VIRTIO_ISO_PATH}"
fmtr::info "It will remain attached to the VM as a CDROM until removed."
echo ""
