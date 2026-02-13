# Attester AMD SEV-SNP <a href="https://github.com/NillionNetwork/attester-amd-sev-snp/blob/main/LICENSE" target="_blank"><img src="https://img.shields.io/badge/License-GPLv3-blue.svg?logo=gnu" alt="GPLv3 License"/></a>

A minimalistic tool for generating AMD SEV-SNP attestation reports with embedded challenges.

## Requirements

**Host:**

- AMD EPYC processor with SEV-SNP support.
- Docker.

## Usage

Run the following in your AMD SEV-SNP enabled host, replacing `<hex-challenge>` with your challenge:

```bash
docker run \
    --privileged \
    --rm \
    -v /lib/modules:/lib/modules \
    -v /boot:/boot \
    ghcr.io/nillionnetwork/amd-attester:0.1.1@sha256:83ef020c050bf1bb8066c7773f4149af2081b7651ed51ab112e626323c5af65a \
    <hex-challenge>
```

The docker container will do the following:

* Start a virtual machine via QEMU.
* Generate an attestation report inside the VM.
* Stop the virtual machine.
* **Validate the attestation report**.
* Print the raw attestation report and the chip id.

