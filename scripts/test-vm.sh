#!/usr/bin/env bash
# Boot installer ISO in QEMU with emulated TPM2. Verifies unattended install
# works end-to-end before committing the USB to real hardware.
set -euo pipefail

ISO=${ISO:-output/bootiso/install.iso}
DISK=${DISK:-output/test-disk.qcow2}
MEM=${MEM:-8G}
CPUS=${CPUS:-4}

if [[ ! -f $ISO ]]; then
    echo "ERROR: $ISO not found. Run 'make iso' first." >&2
    exit 1
fi

TPM_DIR=$(mktemp -d)
trap 'pkill -P $$ 2>/dev/null || true; rm -rf "$TPM_DIR"' EXIT

if [[ ! -f $DISK ]]; then
    qemu-img create -f qcow2 "$DISK" 60G
fi

swtpm socket --tpm2 --tpmstate dir="$TPM_DIR" \
    --ctrl type=unixio,path="$TPM_DIR/swtpm-sock" \
    --log level=20 --daemon

OVMF=/usr/share/edk2/ovmf/OVMF_CODE.fd
[[ -f $OVMF ]] || OVMF=/usr/share/OVMF/OVMF_CODE.fd
[[ -f $OVMF ]] || { echo "ERROR: cannot find OVMF firmware"; exit 1; }

qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -m "$MEM" -smp "$CPUS" \
    -bios "$OVMF" \
    -chardev socket,id=chrtpm,path="$TPM_DIR/swtpm-sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-crb,tpmdev=tpm0 \
    -drive file="$DISK",if=virtio \
    -cdrom "$ISO" \
    -boot d \
    -netdev user,id=n0 -device virtio-net,netdev=n0 \
    -display gtk
