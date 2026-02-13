#!/bin/bash

set -euo pipefail

# Guest script for AMD SEV-SNP attestation
# Runs inside the VM to generate attestation report using a user provided challenge.

if [ $# -ne 3 ]; then
  echo "Usage: $0 <hex-challenge> <output-path> <snpguest-path>"
  exit 1
fi

CHALLENGE="$1"
OUTPUT_PATH=$(realpath "$2")
SNPGUEST_PATH="$3"

# Install extra kernel modules since sev-guest comes as part of it
KERNEL=$(uname -r)

echo "Installing extra modules for kernel $KERNEL"
apt update -qq
apt install -qq -y "linux-modules-extra-$KERNEL"
modprobe sev-guest

WORK_DIR="/tmp/attestation"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

REQUEST_FILE="request.bin"

echo "Creating request file from challenge '$CHALLENGE'"

# Convert hex string to binary
echo "$CHALLENGE" | xxd -r -p >"$REQUEST_FILE"

# Verify file is exactly 64 bytes
FILE_SIZE=$(wc -c "$REQUEST_FILE" | cut -d " " -f 1)
if [ "$FILE_SIZE" -ne 64 ]; then
  echo "Error: Request file is $FILE_SIZE bytes, expected 64 bytes"
  exit 1
fi

echo "Generating attestation report"
if ! "$SNPGUEST_PATH" report "$OUTPUT_PATH" "$REQUEST_FILE" 2>&1; then
  echo "Error: Failed to generate attestation report"
  exit 1
fi

echo "Report generated successfully at $OUTPUT_PATH"
