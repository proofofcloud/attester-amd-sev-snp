#!/bin/bash

set -euo pipefail

# AMD SEV-SNP Attestation Script
# Downloads Ubuntu 25.04, configures QEMU with SEV-SNP, and generates attestation report

CHALLENGE="${1:-}"
if [ -z "$CHALLENGE" ]; then
    echo "Usage: $0 <challenge>"
    echo "Example: $0 deadbeef"
    exit 1
fi

# Validate challenge is hex string
if ! [[ "$CHALLENGE" =~ ^[0-9a-fA-F]+$ ]]; then
    echo "Error: Challenge must be a hexadecimal string"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/.work"
mkdir -p "$WORK_DIR"

UBUNTU_IMAGE="${WORK_DIR}/plucky-minimal-cloudimg-amd64.img"
UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/minimal/daily/plucky/current/plucky-minimal-cloudimg-amd64.img"
DISK_IMAGE="${WORK_DIR}/ubuntu-snp.qcow2"
SEED_IMAGE="${WORK_DIR}/seed.img"
GUEST_SCRIPT="${SCRIPT_DIR}/guest-attest.sh"

# Function to check and install dependencies
install_dependencies() {
    local MISSING_PACKAGES=()
    local NEED_SUDO=false

    # Check if we need sudo
    if [ "$EUID" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "Error: sudo is required but not found. Please install sudo or run as root."
            exit 1
        fi
        NEED_SUDO=true
    fi

    # Check for required commands and corresponding packages
    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        MISSING_PACKAGES+=("qemu-system-x86")
    fi

    if ! command -v qemu-img >/dev/null 2>&1; then
        MISSING_PACKAGES+=("qemu-utils")
    fi

    if ! command -v cloud-localds >/dev/null 2>&1; then
        MISSING_PACKAGES+=("cloud-image-utils")
    fi

    if ! command -v wget >/dev/null 2>&1; then
        MISSING_PACKAGES+=("wget")
    fi

    # Check for OVMF firmware (set global variable)
    OVMF_FIRMWARE="/usr/share/ovmf/OVMF.fd"
    if [ ! -f "$OVMF_FIRMWARE" ]; then
        OVMF_FIRMWARE="/usr/share/qemu/OVMF.fd"
        if [ ! -f "$OVMF_FIRMWARE" ]; then
            MISSING_PACKAGES+=("ovmf")
        fi
    fi

    # Install missing packages
    if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
        echo "Installing missing dependencies: ${MISSING_PACKAGES[*]}"
        if [ "$NEED_SUDO" = true ]; then
            sudo apt-get update
            sudo apt-get install -y "${MISSING_PACKAGES[@]}" || {
                echo "Error: Failed to install dependencies"
                exit 1
            }
        else
            apt-get update
            apt-get install -y "${MISSING_PACKAGES[@]}" || {
                echo "Error: Failed to install dependencies"
                exit 1
            }
        fi
        echo "Dependencies installed successfully."
    fi

    # Verify OVMF firmware location after installation (set global variable)
    OVMF_FIRMWARE="/usr/share/ovmf/OVMF.fd"
    if [ ! -f "$OVMF_FIRMWARE" ]; then
        OVMF_FIRMWARE="/usr/share/qemu/OVMF.fd"
        if [ ! -f "$OVMF_FIRMWARE" ]; then
            echo "Error: OVMF firmware not found after installation"
            exit 1
        fi
    fi
}

# Initialize OVMF_FIRMWARE variable
OVMF_FIRMWARE=""

# Install dependencies automatically
install_dependencies

# Check if guest script exists
if [ ! -f "$GUEST_SCRIPT" ]; then
    echo "Error: Guest script not found: $GUEST_SCRIPT"
    exit 1
fi

echo "=== AMD SEV-SNP Attestation ==="
echo "Challenge: $CHALLENGE"
echo ""

# Download Ubuntu 25.04 cloud image if not present
if [ ! -f "$UBUNTU_IMAGE" ]; then
    echo "Downloading Ubuntu 25.04 minimal cloud image..."
    wget -O "$UBUNTU_IMAGE" "$UBUNTU_IMAGE_URL" || {
        echo "Error: Failed to download Ubuntu image"
        exit 1
    }
    echo "Download complete."
else
    echo "Using existing Ubuntu image: $UBUNTU_IMAGE"
fi

# Create QEMU disk image from cloud image
if [ ! -f "$DISK_IMAGE" ]; then
    echo "Creating QEMU disk image..."
    qemu-img create -f qcow2 -F qcow2 -b "$UBUNTU_IMAGE" "$DISK_IMAGE" 20G || {
        echo "Error: Failed to create disk image"
        exit 1
    }
    echo "Disk image created."
else
    echo "Using existing disk image: $DISK_IMAGE"
fi

# Create cloud-init user-data with guest script
USER_DATA="${WORK_DIR}/user-data"
cat > "$USER_DATA" <<EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

write_files:
  - path: /root/guest-attest.sh
    content: |
$(sed 's/^/      /' "$GUEST_SCRIPT")
    owner: root:root
    permissions: '0755'

runcmd:
  - /root/guest-attest.sh "$CHALLENGE" > /root/attestation-output.txt 2>&1
  - cat /root/attestation-output.txt
  - poweroff

power_state:
  delay: "+1"
  mode: poweroff
  message: "Attestation complete"
EOF

# Create meta-data
META_DATA="${WORK_DIR}/meta-data"
cat > "$META_DATA" <<EOF
instance-id: snp-attestation-$(date +%s)
local-hostname: snp-guest
EOF

# Create cloud-init seed image
echo "Creating cloud-init seed image..."
cloud-localds "$SEED_IMAGE" "$USER_DATA" "$META_DATA" || {
    echo "Error: Failed to create seed image"
    exit 1
}

# Check SEV-SNP support
if [ ! -f /sys/module/kvm_amd/parameters/sev_snp ]; then
    echo "Warning: SEV-SNP may not be available. Continuing anyway..."
fi

# Launch QEMU with SEV-SNP
echo ""
echo "Launching QEMU VM with SEV-SNP..."
echo "This may take a few minutes..."
echo ""

qemu-system-x86_64 \
    -enable-kvm \
    -cpu EPYC-v4 \
    -m 2048 \
    -machine q35,memory-encryption=sev0,vmport=off \
    -object memory-backend-memfd,id=ram1,size=2048M,share=true \
    -machine memory-backend=ram1 \
    -object sev-snp-guest,id=sev0,cbitpos=51,reduced-phys-bits=1,kernel-hashes=on \
    -bios "$OVMF_FIRMWARE" \
    -drive if=virtio,format=qcow2,file="$DISK_IMAGE",id=disk0 \
    -drive if=virtio,format=raw,file="$SEED_IMAGE",id=seed0 \
    -device virtio-net-pci,netdev=net0,iommu_platform=true,disable-legacy=on \
    -netdev user,id=net0 \
    -nographic \
    -serial stdio || {
    echo ""
    echo "Error: QEMU launch failed"
    echo "Note: SEV-SNP requires AMD EPYC hardware or QEMU with SEV-SNP emulation support"
    exit 1
}

echo ""
echo "=== Attestation Complete ==="
