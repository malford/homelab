# Home Assistant

Home Assistant Core runs as a single pod in the `home-assistant` namespace,
backed by one RWO PVC (`home-assistant`) holding its entire state: config,
integrations, automations and the user database.

| Thing | Lives in |
| --- | --- |
| Image pin | `apps/home-assistant/values.yaml` (`containers.main.image.tag`) |
| Config seed | `apps/home-assistant/templates/configmap.yaml` (`configuration.yaml`) |
| State | PVC `home-assistant`, mounted at `/config` |
| Backups | `system/volsync-backups/values.yaml` |
| URL | <https://ha.malford.io> |

There is no ArgoCD `Application` to maintain — the `root` ApplicationSet
generates one from the existence of `apps/home-assistant/`.

## How config reaches the pod

The ConfigMap is a **seed, not a source of truth**, the same pattern
[OpenClaw](openclaw.md) uses. The `init-config` init container copies
`configuration.yaml` onto the PVC only when the file is absent — first
provision, or a restore onto an empty volume. After that Home Assistant owns it,
and its own UI writes to it.

Editing `configmap.yaml` therefore has no effect on a running instance. It
changes what a rebuilt PVC starts from, nothing more.

The init container also seeds empty `automations.yaml`, `scripts.yaml` and
`scenes.yaml`. `configuration.yaml` `!include`s all three, and Home Assistant
refuses to start if an included file is missing.

## Why host networking

Home Assistant discovers LAN devices over mDNS and SSDP, which are broadcast
protocols that do not cross the pod network. `hostNetwork: true` with
`dnsPolicy: ClusterFirstWithHostNet` puts the process on the node's own
interface, so discovery works and cluster DNS still resolves.

Two consequences follow:

- Port 8123 is bound **on the node**, not just in the pod.
- The pod is pinned to `metal0v2` or `metal1v2` via `nodeAffinity`, so the
  address devices call back on stays within a known pair.

`strategy: Recreate` is load-bearing rather than cosmetic. With host networking
*and* an RWO volume, a rolling update's replacement pod can never start — it
collides with the running pod on both host port 8123 and the volume attachment.

!!! note "The node IP flips on reschedule"

    A kured reboot moves the pod between `metal0v2` (192.168.5.113) and
    `metal1v2` (192.168.5.114). Anything that calls back by address — ESPHome
    devices, webhooks — should use `ha.malford.io`, not a node IP. Pinning to a
    single node instead would fix the IP at the cost of availability.

## The reverse proxy requirement

Behind the nginx ingress, Home Assistant answers **every** request with
`400 Bad Request` unless it trusts the proxy. Since 2026.x that setting no
longer lives in `configuration.yaml` — it lives in `/config/.storage/http`, and
the YAML block is migrated into that store exactly **once**:

- On the first start that sees an `http:` block, HA copies it into the store,
  sets `yaml_migration_done: true`, and stages the copy as `pending`.
- `pending` is a **trial**. Unless it is promoted in the UI (Settings → System →
  Network) within five minutes it is marked `error: "not_promoted"`, and HA
  falls back to `stable` — which carries no proxy settings at all.
- Every later boot reads the store and ignores the YAML entirely.

Editing the seed after that first start therefore changes nothing, and
`check_config` will report the YAML as valid while the running server uses
`stable`. Read the truth from the store, not the file:

```sh
kubectl -n home-assistant exec deploy/home-assistant -c main -- \
  cat /config/.storage/http
```

`stable` must contain:

```json
"use_x_forwarded_for": true,
"trusted_proxies": ["10.0.0.0/8", "192.168.5.0/24"]
```

The pod CIDR is `10.0.x.x`, **not** the `10.42.x.x` that `node.spec.podCIDR`
reports — Cilium's own IPAM allocates the addresses pods actually get, and the
k3s field is vestigial. The authoritative answer:

```sh
kubectl get ciliumnode metal1v2 -o jsonpath='{.spec.ipam.podCIDRs}'
```

YAML `http:` is deprecated and breaks in HA 2027.2.0. The seed keeps it only to
cover a genuinely fresh volume; the durable home for proxy trust is the store,
which lives on the PVC and is backed up.

!!! warning "Recovering a store that reverted"

    Once `yaml_migration_done` is set, the only fixes are to promote the trial
    in the UI — which needs a reachable UI — or to write the values straight
    into `stable` and restart. Direct LAN access on port 8123 bypasses the
    proxy and is what makes the first option possible at all.

## First boot

Onboarding is manual and stateful. The first user account is created through the
web UI and lives in `/config/.storage`, not in git. That is what makes the
VolSync entry load-bearing rather than nice-to-have.

A cold start takes 60–90 seconds. The startup probe holds the pod `NotReady`
until 8123 answers, so the ingress returns 503 rather than a broken page in the
meantime.

If the ingress is not up yet, direct LAN access bypasses the proxy entirely:
`http://192.168.5.113:8123` or `http://192.168.5.114:8123`.

## Adding a Zigbee or Z-Wave radio

Not configured. A USB coordinator needs three changes:

1. Pin to the single node the stick is plugged into — narrow `nodeAffinity` to
   one hostname.
2. Mount the device by stable path, not `/dev/ttyUSB0`, which renumbers:

    ```yaml
    persistence:
      zigbee:
        type: hostPath
        hostPath: /dev/serial/by-id/usb-XXXX
        hostPathType: CharDevice
    ```

3. Grant the container access to it — either `privileged: true` or, better, a
   device plugin. `privileged` is what upstream's Compose file uses and is the
   path of least resistance; it is also the reason this deployment omits it
   until a radio actually exists.

Bluetooth is *not* absent, despite no `/run/dbus` mount. `hostNetwork: true`
exposes the node's own adapter, `default_config:` enables the `bluetooth`
integration, and it auto-discovers `hci0` — then fails, because the container
holds no `NET_ADMIN`/`NET_RAW`:

```text
PermissionError: Missing NET_ADMIN/NET_RAW capabilities for Bluetooth management
AttributeError: 'NoneType' object has no attribute 'send'
```

That repeats roughly every four minutes, indefinitely — noisy, but harmless.
Deleting the auto-discovered Bluetooth entry in Settings → Devices & services
stops the retry loop for good. Granting the two capabilities instead would make
Bluetooth actually work, which is a deliberate choice rather than a default.

## Backups

VolSync snapshots the `home-assistant` PVC nightly to the restic REST server,
with the shared 7 daily / 4 weekly / 6 monthly retention. Check the schedule is
live:

```sh
kubectl -n home-assistant get replicationsource home-assistant \
  -o jsonpath='{.status.nextSyncTime}{"\n"}'
```

An empty `nextSyncTime` means a `trigger.manual` key is stuck and the schedule
will never fire again — see [Backup and restore](backup-and-restore.md).

Home Assistant's own backup feature is redundant here and would only consume
space inside the volume being backed up.

## Upgrades

Renovate bumps `containers.main.image.tag` like every other pinned image. Home
Assistant migrates `/config` in place on first start of a new version and does
not support downgrades — a rollback means restoring the PVC from VolSync, not
re-pinning the tag.

Read the [release notes](https://www.home-assistant.io/blog/categories/release-notes/)
for breaking changes before merging a minor bump; they are frequent.
