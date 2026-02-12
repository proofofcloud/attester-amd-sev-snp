FROM ubuntu:25.04

RUN apt update && apt install -y cloud-image-utils qemu-system-x86 ovmf guestmount xxd && \
  mkdir -p /opt/attestation && \
  wget https://cloud-images.ubuntu.com/minimal/daily/plucky/20260113/plucky-minimal-cloudimg-amd64.img -O /opt/attestation/image.qcow2 && \
  wget https://github.com/virtee/snpguest/releases/download/v0.10.0/snpguest -O /opt/attestation/snpguest

COPY launch.sh /opt/attestation/launch.sh
COPY attest.sh /opt/attestation/attest.sh
COPY network-config.yaml /opt/attestation/network-config.yaml

RUN chmod +x /opt/attestation/launch.sh /opt/attestation/snpguest

ENTRYPOINT ["/opt/attestation/launch.sh"]
