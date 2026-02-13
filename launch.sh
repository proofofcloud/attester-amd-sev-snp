#!/bin/bash

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <hex-challenge>"
  exit 1
fi

CHALLENGE="$1"
DISK_IMAGE="/opt/attestation/image.qcow2"
SNPGUEST_PATH="/opt/attestation/snpguest"
OVMF_PATH=/usr/share/ovmf/OVMF.amdsev.fd
GUEST_SCRIPT="/opt/attestation/attest.sh"

# Validate challenge is hex string
if ! [[ "$CHALLENGE" =~ ^[0-9a-fA-F]+$ ]]; then
  echo "Challenge must be a hexadecimal string"
  exit 1
fi

WORK_DIR=$(mktemp -d /tmp/attest.XXXXX)
SEED_IMAGE="${WORK_DIR}/cloud-init-seed.img"

# Ensure challenge is lowercase for consistency
CHALLENGE=$(echo "$CHALLENGE" | tr '[:upper:]' '[:lower:]')

# Pad challenge hex string to 128 hex characters (64 bytes) with zeros
# If challenge is longer than 128 chars, truncate it
CHALLENGE=$(printf "%-128s" "$CHALLENGE" | tr ' ' '0')
CHALLENGE="${CHALLENGE:0:128}"

# Create cloud-init user-data with guest script
USER_DATA="${WORK_DIR}/user-data"
GUEST_SCRIPT_CONTENTS=$(base64 -w 0 "$GUEST_SCRIPT")
cat >"$USER_DATA" <<EOF
#cloud-config

write_files:
  - path: /root/guest-attest.sh
    encoding: b64
    content: $GUEST_SCRIPT_CONTENTS
    owner: root:root
    permissions: '0755'

runcmd:
  - mkdir /tmp/mnt
  - mount /dev/vdb /tmp/mnt
  - /root/guest-attest.sh "$CHALLENGE" /tmp/mnt/report.bin /tmp/mnt/snpguest
  - umount /tmp/mnt
  - poweroff
EOF

# Create cloud-init seed image
cloud-localds --network-config=/opt/attestation/network-config.yaml "$SEED_IMAGE" "$USER_DATA" || {
  echo "Error: Failed to create seed image"
  exit 1
}

# Mount the disk image's to pull the kernel out. We need this since we're booting with kernel-hashes=on which
# requires passing in a `-kernel` to qemu
MOUNT_POINT=$(mktemp -d /tmp/attest.XXXXX)
KERNEL_PATH=vmlinuz
guestmount -a "$DISK_IMAGE" -i --ro "$MOUNT_POINT"

cp "$MOUNT_POINT/boot/vmlinuz" "$KERNEL_PATH"

guestunmount "$MOUNT_POINT"

STATE_DISK=$(mktemp /tmp/attest.XXXX)
mkfs.ext4 -q -F "$STATE_DISK" 128M >/dev/null

mount "$STATE_DISK" "$MOUNT_POINT"
cp "$SNPGUEST_PATH" "$MOUNT_POINT/snpguest"
umount "$MOUNT_POINT"

qemu-system-x86_64 \
  -machine confidential-guest-support=sev0,vmport=off \
  -object sev-snp-guest,id=sev0,cbitpos=51,reduced-phys-bits=1,kernel-hashes=on \
  -enable-kvm \
  -cpu EPYC-v4 \
  -smp 1 \
  -m 1024 \
  -machine q35,accel=kvm \
  -bios "$OVMF_PATH" \
  -kernel "$KERNEL_PATH" \
  -drive file="$DISK_IMAGE",if=none,id=disk0,format=qcow2 \
  -device virtio-scsi-pci,id=scsi0,disable-legacy=on,iommu_platform=true \
  -device scsi-hd,drive=disk0 \
  -display none \
  -append "root=/dev/sda1 panic=-1" \
  -drive if=virtio,format=raw,file="$SEED_IMAGE" \
  -drive if=virtio,format=raw,file="$STATE_DISK" \
  -device virtio-net-pci,disable-legacy=on,iommu_platform=true,netdev=net0,romfile= \
  -netdev user,id=net0 \
  -no-reboot

mount "$STATE_DISK" "$MOUNT_POINT"

if [ ! -f "$MOUNT_POINT/report.bin" ]; then
  echo "Report could not be generated"
  exit 1
fi

REPORT_PATH=$(mktemp /tmp/attest.XXXX)
cp "$MOUNT_POINT/report.bin" "$REPORT_PATH"
umount "$MOUNT_POINT"

# Fetch certificates
CERTS_DIR=./certs
$SNPGUEST_PATH fetch ca pem "$CERTS_DIR" -r "$REPORT_PATH"
$SNPGUEST_PATH fetch vcek pem "$CERTS_DIR" "$REPORT_PATH"

# Verify certificates
if ! $SNPGUEST_PATH verify certs "$CERTS_DIR" >/dev/null; then
  echo "Certificate verification failed"
  exit 1
fi

# Verify attestation, making sure it contains the challenge in the report data  field.
if ! $SNPGUEST_PATH verify attestation -r "0x$CHALLENGE" "$CERTS_DIR" "$REPORT_PATH" >/dev/null; then
  echo "Attestation verification failed"
  exit 1
fi

CHIP_ID=$($SNPGUEST_PATH display report "$REPORT_PATH" | grep "Chip ID:" -A 4 | grep -v "Chip ID:" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
HEX_REPORT=$(xxd -p -c 0 "$REPORT_PATH")

echo "Chip ID: $CHIP_ID"
echo "Attestation report: $HEX_REPORT"
