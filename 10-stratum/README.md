# rocky-stratum

Derived bootc image with the host prerequisites for Stratum nodes. The Stratum
binary is **not** included: it is not publicly distributed, so install it on
each node yourself. One image serves every role (controller, HA controller,
worker); the role is chosen at `stratum up`.

## What it sets up

- `container-selinux`, `policycoreutils-python-utils` and `libselinux-utils`,
  so Stratum can label its files with SELinux left enforcing.
- `iproute-tc`, `iptables-nft` and `bpftool`, which `stratum uninstall` needs.
- Longhorn (V1) host dependencies: `iscsi-initiator-utils` (`iscsid` enabled,
  with a unique InitiatorName generated on first boot), `cryptsetup` and
  `device-mapper`. The NFSv4 client is already in the base.
- `ostree-state-overlay@usr-local.service`, so `/usr/local` is writable for the
  binary at `/usr/local/bin/stratum` (Stratum hardcodes that path).
- `ostree-state-overlay@opt.service`, because the local-path provisioner keeps
  volumes in `/opt/local-path-provisioner` and `/opt` is otherwise read-only.
- `/usr/local/bin` added to sudo's `secure_path` (`/etc/sudoers.d/stratum`), so
  `sudo stratum ...` resolves.
- `bootc-fetch-apply-updates.timer` masked, so nodes don't reboot out from
  under Kubernetes.

## Build

```bash
just stratum
just stratum ghcr.io/ssimpson89/rocky-bootc:latest
```

## Install Stratum

`/usr/local` is read-only on bootc, so the image mounts a state overlay on it
(changes are stored in `/var` and survive OS upgrades). Download the binary
for the node's architecture and install it where Stratum expects it:

```bash
sudo install -m 0755 stratum-linux-amd64 /usr/local/bin/stratum
stratum version
```

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

The OS and Stratum upgrade independently.

**OS:** one node at a time, controllers first: drain, `bootc upgrade` and
reboot, then uncordon. Stratum's binary and state live in `/var`, so it comes
back on the same version.

**Stratum:** copy the new binary to the same path on every node (for example
`/var/tmp/stratum`), then from one controller:

```bash
sudo /var/tmp/stratum upgrade --cluster --from /var/tmp/stratum --yes
```

This takes an etcd snapshot, upgrades controllers one at a time, drains and
gates each node, and installs the new binary to `/usr/local/bin/stratum`.
Don't upgrade by replacing the binary and restarting: that skips the snapshot,
health gates and `stratum rollback`.
