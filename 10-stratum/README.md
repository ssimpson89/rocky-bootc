# rocky-stratum

Derived bootc image for Stratum nodes.
One image serves every role (controller, HA controller, worker); the role is
chosen at join time by `stratum up` flags.

The Stratum binary is not publicly distributed. It never goes in this repo,
and the image is pushed to a **private** package.

## Two versions, upgraded independently

| What | Lives in | Changes when |
|---|---|---|
| OS (kernel, packages) | the image's `/usr` | `bootc upgrade` + reboot |
| Shipped Stratum ("upgrade binary") | `/usr/libexec/stratum/stratum` | `bootc upgrade` + reboot |
| Live Stratum (what `stratum.service` runs) | `/usr/local/bin/stratum` (in `/var`) | only `stratum upgrade` |

On first boot, `stratum-install.service` copies the shipped binary to
`/usr/local/bin/stratum` if nothing is there yet. After that, the image never
touches the live binary: rebuilding the image, even with a newer Stratum,
cannot upgrade a running cluster by itself.

Stratum must be upgraded with `stratum upgrade`, not by swapping its binary.
That path takes the etcd snapshot, gates each control-plane component, drains
nodes, respects version skew, and supports `stratum rollback`. A plain restart
onto a new binary skips all of that.

## Build

```bash
cp ~/Downloads/stratum-linux-arm64 10-stratum/bin/stratum   # gitignored
just stratum v1.37.1-stratum.0
just stratum <version> <binary-path> <base-image>
```

The binary enters through a build secret, so it is never in the build
context. CI (`.github/workflows/stratum-image.yml`) downloads it from Depot
(`STRATUM_DEPOT_URL`, with the `DEPOT_USERNAME`/`DEPOT_TOKEN` secrets),
verifies its `.sha256` sidecar, and tags the image
`<base-tag>-<stratum-version>` plus `latest`.

- **OS-only update:** publish a rocky-bootc release. It rebuilds this image at
  the pinned `STRATUM_VERSION` variable.
- **Stratum update:** run the `stratum-image` workflow by hand with a new
  `stratum_version` (and update the `STRATUM_VERSION` variable so later base
  releases keep it).

## Pulling a private image

Nodes need a read-only pull credential for `bootc upgrade`:

```bash
podman login --authfile /etc/ostree/auth.json ghcr.io -u <user>
chmod 0600 /etc/ostree/auth.json
```

Media built with `just media` embeds the image, so installation itself needs no
credential; the build host does (`podman login ghcr.io`).

## Join

First controller, with the VIP in `/etc/stratum/config.yaml`:

```yaml
spec:
  vip:
    address: 192.168.1.10
```

```bash
sudo stratum up
sudo stratum token create --control-plane   # prints the join, writes a cert-key file
```

Each additional controller (same `spec.vip` in its config, key file copied over):

```bash
sudo stratum up --join https://<vip>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<pin> \
  --certificate-key-file <key-file>
```

Workers, with a token from `stratum token create`:

```bash
sudo stratum up --worker --server https://<vip>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<pin>
```

Run three controllers, not two: etcd needs a majority.

## Upgrading

**OS:** one node at a time, controllers first: `stratum kubectl drain`, then
`bootc upgrade` and reboot, then `uncordon`. Stratum comes back on the same
version.

**Stratum:** once every node has booted an image carrying the new binary,
from one controller:

```bash
sudo stratum upgrade --cluster --from /usr/libexec/stratum/stratum --yes
```

`--from` must be at the same path on every node, which the image guarantees.
Roll back the cluster with `stratum rollback`, and the OS with
`bootc rollback`; they are independent.

## Notes

- `ostree-state-overlay@opt.service` makes `/opt` writable, because the
  local-path provisioner keeps volumes in `/opt/local-path-provisioner`.
- `bootc-fetch-apply-updates.timer` is masked so nodes don't reboot out from
  under Kubernetes.
- SELinux stays enforcing; Stratum labels its own files on first start.
