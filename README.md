# Attester AMD SEV-SNP <a href="https://github.com/NillionNetwork/attester-amd-sev-snp/blob/main/LICENSE" target="_blank"><img src="https://img.shields.io/badge/License-GPLv3-blue.svg?logo=gnu" alt="GPLv3 License"/></a>

A minimalistic tool for generating AMD SEV-SNP attestation reports with embedded challenges.

## Requirements

**Host:**
- AMD EPYC processor with SEV-SNP support (or QEMU with SEV-SNP emulation)
- QEMU >= 9.2, OVMF firmware, cloud-image-utils

**Installation (Ubuntu/Debian):**
Dependencies are automatically installed by the script. Manual installation:
```bash
sudo apt install qemu-system-x86 qemu-utils ovmf cloud-image-utils wget
```

## Verify Before Running

Compare the output with the expected SHA256 hash to ensure the script hasn't been tampered with:

```bash
sha256sum attest.sh
```

## Usage
The host script (`attest.sh`) downloads Ubuntu 25.04, configures QEMU with SEV-SNP, and launches a VM.
The guest script (`guest-attest.sh`) runs inside the VM to install Rust, build [snpguest](https://github.com/virtee/snpguest), generate the attestation report, and extract CPUID.

```bash
./attest.sh deadbeef
```

The challenge must be a hexadecimal string. It will be embedded in the attestation report's `REPORT_DATA` field (padded/truncated to 64 bytes).

### Output

The script outputs three components (matching SGX tool format):
1. **Raw Quote**: Base64-encoded binary attestation report
2. **Quote Verification Report**: Human-readable report with measurements
3. **Platform Identifier**: CPUIDs extracted from the report
