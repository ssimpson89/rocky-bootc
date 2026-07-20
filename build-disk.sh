#!/usr/bin/env bash
# Build disk/installer media from a bootc image via bootc-image-builder.
#
# Usage: ./build-disk.sh <type> [image]
#   type:  qcow2, anaconda-iso, raw, vmdk, vhd, ami, gce, ova, ... (see bib --help)
#   image: bootc image ref (default: ghcr.io/ssimpson89/rocky-kubeadm:latest)
#
# Env overrides: PODMAN, CONFIG, OUTPUT, TARGET_ARCH, BIB
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage: build-disk.sh <type> [image]

  type   qcow2         VM disk image
         anaconda-iso  installer ISO
         raw           raw disk image
         vmdk | vhd | ova | ami | gce | pxe-tar-xz | bootc-installer | iso

  image  bootc image ref (default: ghcr.io/ssimpson89/rocky-kubeadm:latest)

Env overrides: PODMAN, CONFIG, OUTPUT, TARGET_ARCH, BIB

bootc-image-builder requires ROOTFUL podman. On macOS use the rootful
machine connection (or `podman machine set --rootful`):
  PODMAN="podman --connection podman-machine-default-root" ./build-disk.sh qcow2

Examples:
  ./build-disk.sh qcow2
  ./build-disk.sh anaconda-iso ghcr.io/ssimpson89/rocky-bootc:2026.07.02
  TARGET_ARCH=amd64 ./build-disk.sh anaconda-iso
USAGE
    exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
case "$1" in -h|--help) usage ;; esac

TYPE="$1"
IMAGE="${2:-${IMAGE:-ghcr.io/ssimpson89/rocky-kubeadm:latest}}"
PODMAN="${PODMAN:-sudo podman}"
CONFIG="${CONFIG:-config.toml}"
OUTPUT="${OUTPUT:-output}"
BIB="${BIB:-quay.io/centos-bootc/bootc-image-builder:latest}"

if [ ! -f "$CONFIG" ]; then
    echo "Missing $CONFIG: copy config.toml.example to $CONFIG and add your SSH key." >&2
    exit 1
fi

$PODMAN pull "$IMAGE"
mkdir -p "$OUTPUT"

stamp=$(mktemp)
trap 'rm -f "$stamp"' EXIT

$PODMAN run --rm --privileged \
    --security-opt label=disable \
    -v "$(pwd)/$OUTPUT:/output" \
    -v "$(pwd)/$CONFIG:/config.toml:ro" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "$BIB" \
    --type "$TYPE" \
    --chown "$(id -u):$(id -g)" \
    ${TARGET_ARCH:+--target-arch "$TARGET_ARCH"} \
    "$IMAGE"

# Rename artifacts to include image name, tag, and arch so builds don't
# overwrite each other (bib emits generic names like bootiso/install.iso).
ref="${IMAGE##*/}"                      # e.g. rocky-kubeadm:2026.07.02
name="${ref%%:*}"
tag="latest"; [ "$ref" != "${ref#*:}" ] && tag="${ref#*:}"
arch="${TARGET_ARCH:-$(uname -m)}"

echo "Artifacts:"
find "$OUTPUT" -type f -newer "$stamp" | while read -r f; do
    dest="$OUTPUT/${name}-${tag}-${arch}-$(basename "$f")"
    mv "$f" "$dest"
    echo "  $dest"
done
find "$OUTPUT" -mindepth 1 -type d -empty -delete 2>/dev/null || true
