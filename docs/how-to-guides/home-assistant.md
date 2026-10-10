# Home Assistant

Home Assistant Core runs as a single pod in the `home-assistant` namespace,
backed by one RWO PVC (`home-assistant`) holding its entire state: config,
integrations, automations and the user database.

| Thing | Lives in |
| --- | --- |
| Image pin | `apps/home-assistant/values.yaml` (`containers.main.image.tag`) |
| Config seed | `apps/home-assistant/templates/configmap.yaml` (`configuration.yaml`) |
| HACS pin | `apps/home-assistant/values.yaml` (`initContainers.init-hacs.env.HACS_VERSION`) |
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
interface, so discovery reaches the LAN and cluster DNS still resolves.

Host networking only buys the node's own broadcast domain, though. The nodes
have a single LAN NIC (`eno1`) on the cluster VLAN, so discovery stops at
`192.168.5.0/24` — see [Cross-VLAN discovery](#cross-vlan-discovery).

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

## Cross-VLAN discovery

The LAN is split three ways, and Home Assistant sits on none of the segments
its devices or controllers live on:

| VLAN             | Contents                                              |
| ---------------- | ----------------------------------------------------- |
| `192.168.2.0/24` | IoT — LIFX, TP-Link plugs, Midea AC, Modern Forms fans |
| `192.168.3.0/24` | Clients — laptops, phones, tablets                    |
| `192.168.5.0/24` | k3s cluster — Home Assistant on `metal0v2`/`metal1v2`  |

mDNS is link-local multicast (224.0.0.251, TTL 1), so it does not route. The
**gateway mDNS proxy must be enabled on all three VLANs** — enabling it on a
subset silently breaks whichever direction is missing.

Anything that depends on discovery rather than a known address needs this:
HomeKit (`_hap._tcp`), Chromecast, AirPlay, SSDP/DLNA, Spotify Connect.

!!! warning "Reachability tests do not prove discovery"

    Unicast routing between VLANs is open, so `curl` and
    `nc -vz 192.168.5.114 21064` succeed even when the mDNS proxy is off. A
    passing connectivity check tells you nothing about whether a controller can
    *find* the service. Check discovery directly from a client instead:

    ```sh
    dns-sd -B _hap._tcp          # runs until Ctrl-C; absence is the signal
    ```

    If the service is listening and the logs are clean but it never appears in
    that browse, suspect the mDNS proxy before touching the app config.

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

## HACS

[HACS](https://hacs.xyz) is installed by the `init-hacs` init container, not by
hand. Upstream's documented container install is:

```sh
docker exec -it <container> bash
wget -O - https://get.hacs.xyz | bash -
```

That cannot work here for two reasons. The command is imperative — anything it
writes is undone the moment the pod is replaced onto a fresh volume — and
[the script](https://github.com/hacs/get/blob/main/get) hard-requires both
`wget` and `unzip`, while the Home Assistant image ships only `wget`.

So the init container does the same work declaratively, from Alpine, which has
both:

1. Compare `custom_components/hacs/.hacs-chart-version` against `HACS_VERSION`.
   Equal, and it exits without touching anything.
2. Otherwise download that exact release, unzip it to a staging directory
   **on the PVC**, and only then swap it over the live one.

Staging before the swap is deliberate. Upstream deletes the existing install
*before* it validates anything, so a failed download or a too-old Home Assistant
leaves you with no HACS at all. Here the old directory is removed only once a
good copy is extracted, and the staging path is on the same filesystem so the
final `mv` is a rename rather than a copy.

### Changing the version

`HACS_VERSION` in `values.yaml` is the source of truth. Bump it, commit, and
ArgoCD rolls a pod that reconciles to it.

!!! warning "A HACS self-update is reverted on the next pod restart"

    HACS can update *itself* from Settings → HACS, and that update writes to
    `custom_components/hacs` — which the init container reconciles on every pod
    start. Updating in the UI therefore holds only until the next restart, and a
    kured reboot is enough to roll it back.

    This is the same contract as `image.tag`: the version in git wins. To take a
    new HACS release, bump `HACS_VERSION` rather than clicking update. Check the
    release's `MINIMUM_HA_VERSION` against the image pin first — HACS 2.0.5
    requires Home Assistant 2024.4.1 or newer.

Confirm what is actually installed:

```sh
kubectl -n home-assistant exec deploy/home-assistant -c main -- \
  cat /config/custom_components/hacs/.hacs-chart-version
```

Or read the install itself, which logs one line either way:

```sh
kubectl -n home-assistant logs deploy/home-assistant -c init-hacs
```

### Setting it up is still manual

Installing the code is all the chart can do. Like onboarding, the rest is
stateful and lives in `/config/.storage`, not in git:

1. Restart Home Assistant, then add HACS under Settings → Devices & services →
   Add integration.
2. Complete the GitHub device-flow authorization it prompts for.

That GitHub token cannot be provisioned declaratively — the device flow needs a
human at github.com. It is why a restore matters more than a reinstall here: the
token and the list of downloaded repositories come back with the PVC, and
nothing in git can recreate them.

### What HACS downloads is not reinstalled for you

Integrations, themes and Lovelace plugins that HACS downloads land **outside**
`custom_components/hacs` — in sibling `custom_components/<name>` directories,
plus `themes/` and `www/community/`. The init container never touches those, so
reconciling the HACS version leaves them alone.

They are also not in git. They survive because they are on the PVC and the PVC
is backed up; a restore brings them back, a fresh volume does not.

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

One PVC holds everything under `/config`, so the whole of HACS is already
covered by that single entry — no second backup target was needed for it:

| HACS state | Path on the PVC | Recreated by git? |
| --- | --- | --- |
| Integration code | `custom_components/hacs/` | Yes — `init-hacs` reinstalls it |
| GitHub token, repo list | `.storage/hacs.*` | No |
| Downloaded integrations | `custom_components/<name>/` | No |
| Downloaded themes, plugins | `themes/`, `www/community/` | No |

Only the first row is reproducible from the chart. Everything else exists solely
because the volume is backed up, which is the same reason the onboarding account
is load-bearing.

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
