#!/usr/bin/env bash
# Helper script to perform privileged operations for Gaming Mode Daemon
# Executed via sudo by the gaming-mode-daemon.sh

COMMAND="$1"
shift

case "$COMMAND" in
    bind_gpu)
        PCI_ADDR="$1"
        TARGET_DRIVER="$2"
        sys_path="/sys/bus/pci/devices/${PCI_ADDR}"
        
        current=$(readlink "${sys_path}/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        if [[ "$current" != "none" ]]; then
            echo "${PCI_ADDR}" > "/sys/bus/pci/drivers/${current}/unbind" 2>/dev/null || true
            sleep 0.5
        fi
        
        echo -n > "${sys_path}/driver_override" 2>/dev/null || true
        sleep 0.5
        echo "${TARGET_DRIVER}" > "${sys_path}/driver_override"
        sleep 0.5
        echo "${PCI_ADDR}" > "/sys/bus/pci/drivers/${TARGET_DRIVER}/bind"
        ;;
    release_console)
        echo 0 > /sys/class/vtconsole/vtcon0/bind 2>/dev/null || true
        echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null || true
        echo "efi-framebuffer.0" > /sys/bus/platform/drivers/efi-framebuffer/unbind 2>/dev/null || true
        ;;
    bind_console)
        echo 1 > /sys/class/vtconsole/vtcon0/bind 2>/dev/null || true
        echo 1 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null || true
        echo "efi-framebuffer.0" > /sys/bus/platform/drivers/efi-framebuffer/bind 2>/dev/null || true
        ;;
    load_vfio)
        modprobe vfio-pci 2>/dev/null || true
        modprobe vfio 2>/dev/null || true
        modprobe vfio_iommu_type1 2>/dev/null || true
        ;;
    setup_kvmfr)
        USER_NAME="$1"
        modprobe kvmfr static_size_mb=64 2>/dev/null || true
        sleep 1
        if [[ -e /dev/kvmfr0 ]]; then
            chown "${USER_NAME}:kvm" /dev/kvmfr0 2>/dev/null || true
        fi
        ;;
    *)
        echo "Unknown command"
        exit 1
        ;;
esac
