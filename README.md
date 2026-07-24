# Rocky Linux Bootable Container (bootc)

Builds Rocky Linux 10 bootable container images using the [bootc
framework](https://containers.github.io/bootc/).

Based on the [CentOS Bootc Base Images](https://gitlab.com/redhat/centos-stream/containers/bootc)
tooling and [bootc-base-imagectl](https://gitlab.com/fedora/bootc/base-images/-/blob/main/bootc-base-imagectl.md).

## Images

- **`rocky-bootc`** (`10-base/`) — the Rocky Linux 10 bootc base image.
- **`rocky-kubeadm`** (`10-kubeadm-worker/`) — a derived Kubernetes node image
  (kubeadm/kubelet + containerd, Longhorn host deps). See
  [`10-kubeadm-worker/README.md`](10-kubeadm-worker/README.md), including how to
  join it to a cluster.

## Prerequisites

* [`just`](https://just.systems/)
* `podman`
* Sufficient disk space and internet connectivity

On Linux, recipes use `sudo podman` by default. Set `SUDO=` for rootless
Podman. On macOS, recipes use `podman` directly; disk-media builds require the
Podman machine to be configured as rootful:

```bash
podman machine stop
podman machine set --rootful
podman machine start
```

## Building images

```bash
just base                    # rocky-bootc, linux/amd64
just base linux/arm64        # rocky-bootc, linux/arm64
just kubeadm                 # derived from the local rocky-bootc image
just kubeadm <base-image>    # derived from a published base image
```

Set `IMAGE_NAME` or `KUBEADM_IMAGE` to override the local output names. Run
`just --list` to see all recipes.

## How it works

The base build is one multi-stage Containerfile invocation:

1. **repos stage**: extracts Rocky Linux 10 repo configs and GPG keys from the
   official `quay.io/rockylinux/rockylinux:10` image.
2. **builder stage**: uses `quay.io/centos-bootc/centos-bootc:stream10` as the
   build environment and runs `bootc-base-imagectl` with the `rocky-10.yaml`
   manifest to compose the rootfs.
3. **unchunked stage**: assembles the composed rootfs from scratch.
4. **rechunker stage**: uses
   [`chunkah`](https://github.com/coreos/chunkah) to create content-addressed
   OCI layers, maximizing reuse between image versions.
5. **final stage**: adds the bootc metadata and validates the chunked image.

The compose requires nested-container privileges and FUSE access; the `base`
recipe supplies those build flags and removes the temporary OCI archive.

## Releases

Publishing a GitHub Release triggers `.github/workflows/release-image.yml`,
which:

1. runs the same `just base` recipe natively for `amd64` and `arm64`, then
   publishes a multi-arch manifest tagged with the release tag and `latest`;
2. builds `rocky-kubeadm` on top of that release tag and publishes it as its own
   multi-arch image.

The release tag doubles as the image version. Registry and image names come from
Actions variables, so nothing is hardcoded.

## Disk images

The builds above produce OCI container images, which is what `bootc upgrade`
consumes. To create installable media, use
[bootc-image-builder](https://github.com/osbuild/image-builder/tree/main/bootc-image-builder):

```bash
cp config.toml.example config.toml   # add your SSH key (login user for the installed OS)
just media anaconda-iso              # installer ISO
just media qcow2                     # VM disk image
just media vmdk                      # any supported image type
```

The optional second and third arguments select the source image and target
architecture:

```bash
just media qcow2 ghcr.io/ssimpson89/rocky-kubeadm:2026.07.03 amd64
```

Artifacts retain bootc-image-builder's standard layout under `output/`, such
as `output/qcow2/disk.qcow2` and `output/bootiso/install.iso`. Persistent
`bib-store` and `bib-rpmmd` volumes speed up repeat builds; use `CACHE=0 just
media ...` on disk-constrained hosts. Cross-architecture media builds run under
emulation, so native builds are faster and more reliable.
