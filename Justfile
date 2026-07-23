# Local and CI entry point. Run `just --list` to see available recipes.

project_dir := justfile_directory()
sudo := env("SUDO", if os() == "macos" { "" } else { "sudo" })
podman := sudo + (if sudo == "" { "" } else { " " }) + "podman"

image_name := env("IMAGE_NAME", "rocky-bootc")
kubeadm_image := env("KUBEADM_IMAGE", "rocky-kubeadm")
base_ref := env("BASE_REF", "localhost/rocky-bootc:latest")

disk_image := env("DISK_IMAGE", "ghcr.io/ssimpson89/rocky-kubeadm:latest")
bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")
config := env("CONFIG", project_dir + "/config.toml")
output := env("OUTPUT", project_dir + "/output")
cache := env("CACHE", "1")

# Show the available recipes.
[group('help')]
default:
    @echo "Run 'just --list' to see available recipes."

# Build the Rocky base image with content-addressed layers.
[group('images')]
base platform="linux/amd64":
    #!/usr/bin/env bash
    set -euo pipefail
    archive="{{ project_dir }}/out.ociarchive"
    trap 'rm -f "$archive"' EXIT
    {{ podman }} build \
        --platform "{{ platform }}" \
        --security-opt label=disable \
        --cap-add all \
        --device /dev/fuse \
        --build-arg FINAL=chunked \
        --build-arg "CHUNKED_IMAGE=oci-archive:${archive}" \
        --skip-unused-stages=false \
        --volume "{{ project_dir }}:/run/src" \
        --tag "{{ image_name }}" \
        --file "{{ project_dir }}/10-base/Containerfile" \
        "{{ project_dir }}"

# Build the kubeadm image from a local or published base image.
[group('images')]
kubeadm base=base_ref:
    {{ podman }} build \
        --build-arg "BASE_IMAGE={{ base }}" \
        --tag "{{ kubeadm_image }}" \
        --file "{{ project_dir }}/10-kubeadm-worker/Containerfile" \
        "{{ project_dir }}/10-kubeadm-worker"

# Examples:
#   just media
#   just media anaconda-iso
#   just media qcow2 ghcr.io/example/rocky-kubeadm:tag amd64
#
# Convert a published bootc image into disk or installer media.
[group('media')]
media type="qcow2" image=disk_image arch="":
    #!/usr/bin/env bash
    set -euo pipefail

    config="{{ config }}"
    output="{{ output }}"
    arch="{{ arch }}"
    cache="{{ cache }}"

    if [[ ! -f "$config" ]]; then
        echo "Missing $config: copy config.toml.example to config.toml and add your SSH key." >&2
        exit 1
    fi

    mkdir -p "$output"

    arch_args=()
    target_args=()
    if [[ -n "$arch" ]]; then
        arch_args=(--arch "$arch")
        target_args=(--target-arch "$arch")
    fi

    cache_args=()
    if [[ "$cache" == "1" ]]; then
        cache_args=(--volume bib-store:/store --volume bib-rpmmd:/rpmmd)
    fi

    {{ podman }} pull "${arch_args[@]}" "{{ image }}"
    {{ podman }} run \
        --rm \
        --privileged \
        --pull newer \
        --security-opt label=type:unconfined_t \
        "${arch_args[@]}" \
        --volume "$output:/output" \
        --volume "$config:/config.toml:ro" \
        --volume /var/lib/containers/storage:/var/lib/containers/storage \
        "${cache_args[@]}" \
        "{{ bib_image }}" \
        --type "{{ type }}" \
        --use-librepo=true \
        --chown "$(id -u):$(id -g)" \
        "${target_args[@]}" \
        "{{ image }}"
