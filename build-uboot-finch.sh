#!/usr/bin/env bash
# macOS: build u-boot.itb in a pinned native-arm64 Linux container (Finch). Wraps build-uboot.sh.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${IMAGE:-debian:bookworm-slim}"

command -v finch >/dev/null || { echo "Install Finch: brew install finch"; exit 1; }
finch vm status 2>/dev/null | grep -qi running || finch vm start 2>/dev/null || finch vm init

finch run --rm -v "$PWD:/repo" -w /repo "$IMAGE" sh -c '
  apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    git ca-certificates build-essential bison flex libssl-dev libgnutls28-dev \
    device-tree-compiler bc python3 python3-dev python3-setuptools python3-pyelftools swig &&
  ./build-uboot.sh'
