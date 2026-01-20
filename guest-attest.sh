#!/bin/bash

set -euo pipefail

# Guest script for AMD SEV-SNP attestation
# Runs inside the VM to generate attestation report with challenge

CHALLENGE="${1:-}"
if [ -z "$CHALLENGE" ]; then
    echo "Error: Challenge argument required"
    exit 1
fi

# Validate challenge is hex string
if ! [[ "$CHALLENGE" =~ ^[0-9a-fA-F]+$ ]]; then
    echo "Error: Challenge must be a hexadecimal string"
    exit 1
fi

WORK_DIR="/tmp/attestation"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "=== AMD SEV-SNP Guest Attestation ==="
echo "Challenge: $CHALLENGE"
echo ""

# Install dependencies
echo "Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git build-essential pkg-config libssl-dev vim-common >/dev/null 2>&1

# Install Rust
echo "Installing Rust toolchain..."
if ! command -v rustc >/dev/null 2>&1; then
    # Ensure HOME is set (may not be set when running as root via cloud-init)
    export HOME="${HOME:-/root}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable >/dev/null 2>&1
    source "$HOME/.cargo/env"
fi

# Verify Rust installation
rustc --version || {
    echo "Error: Rust installation failed"
    exit 1
}

# Clone and build snpguest
echo "Building snpguest..."
SNPGUEST_DIR="${WORK_DIR}/snpguest"
if [ ! -d "$SNPGUEST_DIR" ]; then
    git clone --quiet https://github.com/virtee/snpguest.git "$SNPGUEST_DIR"
fi
cd "$SNPGUEST_DIR"
git pull --quiet || true

# Build snpguest
cargo build --release || {
    echo "Error: Failed to build snpguest"
    exit 1
}

SNPGUEST_BIN="${SNPGUEST_DIR}/target/release/snpguest"

# Verify snpguest binary exists
if [ ! -f "$SNPGUEST_BIN" ]; then
    echo "Error: snpguest binary not found at $SNPGUEST_BIN"
    exit 1
fi

cd "$WORK_DIR"

# Create 64-byte request file from challenge
# Convert hex string to binary, padding to 64 bytes
REQUEST_FILE="${WORK_DIR}/request.bin"
REPORT_FILE="${WORK_DIR}/report.bin"

echo "Creating request file from challenge..."

# Ensure challenge is lowercase for consistency
CHALLENGE=$(echo "$CHALLENGE" | tr '[:upper:]' '[:lower:]')

# Pad challenge hex string to 128 hex characters (64 bytes) with zeros
# If challenge is longer than 128 chars, truncate it
PADDED_CHALLENGE=$(printf "%-128s" "$CHALLENGE" | tr ' ' '0')
PADDED_CHALLENGE="${PADDED_CHALLENGE:0:128}"

# Convert hex string to binary using xxd (more reliable than sed)
echo "$PADDED_CHALLENGE" | xxd -r -p > "$REQUEST_FILE"

# Verify file is exactly 64 bytes
FILE_SIZE=$(stat -c%s "$REQUEST_FILE" 2>/dev/null || stat -f%z "$REQUEST_FILE" 2>/dev/null || echo "0")
if [ "$FILE_SIZE" -ne 64 ]; then
    echo "Error: Request file is $FILE_SIZE bytes, expected 64 bytes"
    exit 1
fi

echo "Request file created: $(xxd -p -l 64 "$REQUEST_FILE" | tr -d '\n')"

# Generate attestation report
echo "Generating attestation report..."
if ! "$SNPGUEST_BIN" report "$REPORT_FILE" "$REQUEST_FILE" 2>&1; then
    echo ""
    echo "Error: Failed to generate attestation report"
    exit 1
fi

# Verify report was created
if [ ! -f "$REPORT_FILE" ]; then
    echo "Error: Attestation report not generated"
    exit 1
fi

echo ""
echo "=== Raw Quote (Base64 Encoded) ==="
base64 -w 0 "$REPORT_FILE"
echo ""
echo ""

# Display report
echo "=== Quote Verification Report ==="
"$SNPGUEST_BIN" display report "$REPORT_FILE" || {
    echo "Error: Failed to display report"
    exit 1
}

echo ""

# Extract CPUIDs and platform information from report
echo "=== Platform Identifier (CPUIDs) ==="
REPORT_OUTPUT=$("$SNPGUEST_BIN" display report "$REPORT_FILE" 2>/dev/null || echo "")

# Extract CPUID values from report output
# snpguest display report shows CPUID in format like:
# CPUID[0x00000000]: 0x0000000d 0x68747541 0x444d4163 0x69746e65
# or similar format
CPUID_LINES=$(echo "$REPORT_OUTPUT" | grep -iE "cpuid|family|model|stepping" || true)

if [ -n "$CPUID_LINES" ]; then
    echo "$CPUID_LINES"
else
    # Try to extract CPUID patterns from the full output
    echo "$REPORT_OUTPUT" | grep -iE "cpuid|0x[0-9a-f]{8}" | head -20 || echo "CPUID information extracted from report display"
fi

# Extract additional platform identifiers
echo ""
echo "=== Additional Platform Information ==="
echo "Report size: $(stat -c%s "$REPORT_FILE" 2>/dev/null || stat -f%z "$REPORT_FILE" 2>/dev/null || echo "unknown") bytes"
echo "Challenge (hex): $(xxd -p -l 64 "$REQUEST_FILE" | tr -d '\n')"

# Try to extract VCEK, TCB version, and other identifiers from report
VCEK_INFO=$(echo "$REPORT_OUTPUT" | grep -iE "vcek|tcb|version" | head -5 || true)
if [ -n "$VCEK_INFO" ]; then
    echo ""
    echo "Platform Version Information:"
    echo "$VCEK_INFO"
fi

echo ""
echo "=== Attestation Complete ==="
