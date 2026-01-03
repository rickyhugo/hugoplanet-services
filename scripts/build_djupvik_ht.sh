#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$SCRIPT_DIR/../services/djupvik-ht"
REGISTRY="${REGISTRY:-ghcr.io/rickyhugo}"
IMAGE_NAME="${IMAGE_NAME:-hugoplanet-djupvik-ht}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
PUSH="${PUSH:-false}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

cd "$SERVICE_DIR"

# Clean previous builds
rm -rf zig-out

echo "Building Zig binaries for multiple platforms..."

# Build for amd64
echo "  -> x86_64-linux..."
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux
mkdir -p zig-out/bin/linux/amd64
mv zig-out/bin/djupvik_ht zig-out/bin/linux/amd64/

# Build for arm64 (Raspberry Pi)
echo "  -> aarch64-linux..."
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux
mkdir -p zig-out/bin/linux/arm64
mv zig-out/bin/djupvik_ht zig-out/bin/linux/arm64/

echo "Building Docker image ${FULL_IMAGE} for ${PLATFORMS}..."

if [[ "$PUSH" == "true" ]]; then
  docker buildx build \
    --platform "$PLATFORMS" \
    --tag "$FULL_IMAGE" \
    --push \
    .
else
  # Load only works for single platform, build for current arch
  CURRENT_ARCH="linux/$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')"
  docker buildx build \
    --platform "$CURRENT_ARCH" \
    --tag "$FULL_IMAGE" \
    --load \
    .
fi

echo "Done."
