#!/bin/bash

set -euo pipefail

# This encapsulates the `docker run` command and its parameters in a single
# script, to make it easier to run inside environments where copy/pasting is
# not possible

if [ $# -ne 1 ]; then
  echo "Usage: $0 <hex-challenge>"
  exit 1
fi

docker run \
  --privileged \
  --rm \
  -v /lib/modules:/lib/modules \
  -v /boot:/boot \
  ghcr.io/proofofcloud/amd-attester:0.2.1@sha256:eee07287e235b7de3de7016bd18e91e28f3dd99e8e4f88ea0e47cfdc59fd789e \
  $1
