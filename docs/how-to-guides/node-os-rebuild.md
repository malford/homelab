# Rebuild a node's OS

One node at a time: drain it, let it PXE boot, reinstall, rejoin. The cluster
stays up throughout because all four Ceph pools are `size=2, min_size=1` and the
control plane keeps etcd quorum with five of six servers.

Target OS is AlmaLinux 10.2. See [PXE boot](../concepts/pxe-boot.md) for how the
boot handshake works.

!!! danger "The first pass destroys every OSD"

    Today's OSD lives on LV `system/ceph`, which the old kickstart created inside
    the single OS volume group. The new layout puts the OSD on its own partition
    (`p4`, VG `ceph`, LV `osd`), so a node in the **old** layout is repartitioned
    from scratch and its OSD is lost. Each rebuild therefore costs one full
    backfill this round. The preserved-OSD path only pays off from the *second*
    rebuild of a node onward.

## Rebuild order

Ceph's failure domain is the host and every pool is `size=2`, so no surviving
host may end up holding more than half the logical data. metal0v2 and metal1v2
carry ~72% of it between them, so they go last.

| Order | Node | Why here |
| ----- | -------- | -------- |
| 1 | `metal3v2` | OSD-only, smallest OSD by usage — the cheapest backfill and the pass that proves the new `%pre` |
| 2 | `metal2v2` | OSD-only |
| 3 | `metal5v2` | OSD-only |
| 4 | `metal4v2` | Adds a mon failover to the exercise |
| 5 | `metal1v2` | Large OSD, plus mgr/mon/mds |
| 6 | `metal0v2` | Large OSD, and it is `groups['masters'][0]` |

!!! tip "Prove the partition scheme before spending the fleet"

    There is no staging cluster. The only unproven piece is the `%pre` block, so
    rebuild `metal3v2` **twice**: once to lay down the new layout, then again to
    confirm `p4` survives and the OSD is re-adopted without a backfill. If the
    second pass fails, you have lost one small node's data and nothing else.

## Preflight (once, before node 1)

Push the MDS anti-affinity and the Rook device list first — the MDS fix is what
keeps CephFS alive when a node goes away.

```sh
git push origin main && git push gitea main
```

Set up a Ceph CLI shim. There is no toolbox pod, and the `-m` flag is mandatory.

```sh
MONS=$(kubectl -n rook-ceph get cm rook-ceph-mon-endpoints -o jsonpath='{.data.data}' | sed 's/[a-z]*=//g')
ceph() { kubectl -n rook-ceph exec deploy/rook-ceph-mgr-a -c mgr -- ceph "$@" --name mgr.a --keyring /etc/ceph/keyring-store/keyring -m "$MONS"; }
```

!!! note

    Swap `mgr-a` for `mgr-b` if `a` is the standby. The `mgr.a` keyring lacks caps
    for some commands, which fail with exit 13, `EACCES: access denied: does your
    client key have mgr caps?`. Known cases: `ceph osd df` (use the Grafana Ceph
    boards or Prometheus for per-OSD utilisation) and `ceph osd purge` (use the
    `kubectl rook-ceph` plugin from the Mac, which has full toolbox-equivalent
    access).

- [ ] MDS pods are on **different** nodes:
      `kubectl -n rook-ceph get pods -l app=rook-ceph-mds -o wide`
- [ ] `ceph -s` reports `HEALTH_WARN` only for the known insecure-key-type checks,
      all PGs `active+clean`, `6 osds: 6 up, 6 in`, `mon: 3 daemons, quorum`
- [ ] `ceph df` headroom is sane — raw use is ~31% and `nearfull_ratio` is 0.85;
      removing a small node pushes the three remaining smalls to ~17%, removing
      metal0v2 or metal1v2 pushes the four smalls to ~65%
- [ ] etcd snapshots are current on every node:

```sh
kubectl get nodes -o custom-columns='NODE:.metadata.name,SNAPSHOT:.metadata.annotations.etcd\.k3s\.cattle\.io/local-snapshots-timestamp'
```

- [ ] Record the pre-rebuild etcd membership so you can tell a stale member from a
      new one:

```sh
kubectl get nodes -o custom-columns='NODE:.metadata.name,MEMBER:.metadata.annotations.etcd\.k3s\.cattle\.io/node-name'
```

!!! warning "`k3s_cluster_init` now defaults to false"

    The next `cluster.yml` run renders `server: https://192.168.5.100:6443` on
    metal0v2 where it previously rendered `cluster-init: true`. That is a config
    change, so the `Restart k3s` handler fires once on metal0v2. It is safe: k3s
    ignores **both** flags whenever an etcd datastore already exists on disk. The
    flag only mattered for a wiped node, where honouring it would have initialised
    a brand new empty cluster instead of joining this one.

## Per node

Export the node once so the rest of the block copy-pastes.

```sh
NODE=metal3v2
```

### 1. Record what lives there

```sh
kubectl -n rook-ceph get pods -o wide --field-selector spec.nodeName=$NODE
ceph osd tree
```

Note the OSD id on this node as `OSD_ID`.

### 2. Drain the OSD

```sh
ceph osd out $OSD_ID
```

Wait for recovery to finish — this is the long step (minutes for a small node,
closer to an hour for metal0v2/metal1v2).

```sh
ceph -s   # repeat until all PGs are active+clean again
```

!!! warning "Do not purge the OSD yet"

    The CephCluster runs `useAllNodes: true`, so the operator provisions an OSD on
    **any schedulable node** holding one of the listed devices. While the node is
    still schedulable, a reconcile recreates the OSD deployment, re-adopts the
    BlueStore device, and puts the OSD back `in` at full weight — undoing both the
    `out` and a completed purge. Purge only after the drain has cordoned the node,
    in step 3.

    `removeOSDsIfOutAndSafeToRemove: true` is not a substitute. Observed
    2026-10-16: with the OSD out for 15 minutes and both `ceph osd safe-to-destroy`
    and `ceph osd ok-to-stop` returning yes, the operator created **no purge job at
    all**.

### 3. Drain the node and purge the OSD

```sh
kubectl drain $NODE --delete-emptydir-data --ignore-daemonsets --force
```

The drain cordons the node, which is what finally stops the operator from
re-provisioning the OSD. Now stop the daemon and purge. `ceph osd out` only
removes the OSD from data placement — the daemon keeps running, and `purge`
refuses a live OSD with `EBUSY: osd.N is not 'down'`:

```sh
kubectl -n rook-ceph scale deploy rook-ceph-osd-$OSD_ID --replicas=0
ceph osd tree   # repeat until the OSD reads `down`
ceph osd purge $OSD_ID --yes-i-really-mean-it
kubectl -n rook-ceph delete deploy rook-ceph-osd-$OSD_ID
```

!!! note "`purge` needs the plugin, not the shim"

    `ceph osd purge` is one of the commands the `mgr.a` keyring cannot run — it
    fails with exit 13, `EACCES: access denied: does your client key have mgr
    caps?`. Run it as `kubectl rook-ceph ceph osd purge ...` from the Mac instead.

Confirm the OSD is gone and stays gone, then remove the node:

```sh
ceph osd tree           # no entry for $OSD_ID, and the host bucket is empty
kubectl delete node $NODE
```

`kubectl delete node` is what triggers k3s to remove the matching etcd member.
Confirm the member suffix rotated before continuing — a rebuilt node rejoins
under a new one, so the old member must be gone:

```sh
kubectl get nodes -o custom-columns='NODE:.metadata.name,MEMBER:.metadata.annotations.etcd\.k3s\.cattle\.io/node-name'
```

!!! warning "`delete node` does not keep the node out"

    k3s is still running on the box, so it re-registers within a few minutes —
    **uncordoned and untainted**. Observed 2026-10-16: metal3v2 was back 4
    minutes later, which puts `/dev/mapper/system-ceph` back in reach of
    `useAllNodes: true`. Re-apply the cordon before moving on:

    ```sh
    kubectl cordon $NODE
    ```

### 4. Power it off

On the ThinkCentre M910q, **no disk surgery is needed** — the firmware has two
independent boot lists, and the one that governs a Wake-on-LAN power-on already
prefers the network:

| BIOS list | Applies to | Order |
| --- | --- | --- |
| Primary Boot Sequence | Power-button / OS-initiated reboot | M.2 Drive 1, then Network 1 |
| Automatic Boot Sequence | WoL, RTC wake, power restore | **Network 1**, then M.2 Drive 1 |

`boot.yml` wakes the node with a magic packet, so the Automatic sequence applies
and it PXE boots on its own. All step 4 needs is a clean shutdown:

```sh
ssh root@$NODE poweroff
```

!!! tip "If you power it on by hand, press F12"

    A power-button start uses the *Primary* sequence and boots the disk. Use the
    F12 one-time boot menu and pick the network device instead. Optionally move
    `Network 1` first in the Primary sequence too — harmless, since the PXE
    server only runs while `boot.yml` is running and any other boot just falls
    through to the disk after a short timeout.

!!! danger "Do not try to force PXE by damaging the disk"

    `sgdisk --zap-all` or `wipefs -a /dev/nvme0n1` destroys `p4` and the OSD with
    it. `sgdisk` is not even installed — `gdisk` is not in
    `@^minimal-environment`.

    Wiping just the ESP (`wipefs -a /dev/nvme0n1p1`) is worse than useless.
    Observed 2026-10-16 on metal3v2: it clears the vfat *signature* but leaves
    every file in place, so the firmware still loads
    `\EFI\BOOT\BOOTX64.EFI` and reaches GRUB — deleting the `efibootmgr` entries
    does not prevent it, because that fallback path needs no NVRAM entry. The
    only thing it accomplishes is making the `/boot/efi` fstab entry
    unsatisfiable, so the node boots to **emergency mode** and the `wake` play
    times out waiting for SSH. If a node is already in that state, power it off
    and let PXE run; `%pre` rewrites p1–p3 regardless.

### 5. Reinstall

From the jump box. `localhost` must stay in the `boot.yml` limit or the
`pxe_server` play is skipped and nothing serves the kickstart.

```sh
cd metal
ansible-playbook -i inventories/prod.yml boot.yml --limit "localhost,$NODE"
```

!!! note "Confirm the PXE tree is the one you think it is"

    The jump box served the Fedora 39 tree from early 2024 until the AlmaLinux
    bump. The run downloads the ISO (~1 GB), clears `files/data/os`, re-extracts,
    normalises permissions, and recreates both containers so they pick up the new
    `vmlinuz`/`initrd.img`:

    ```sh
    ls roles/pxe_server/files/data/os/.extracted-from-*
    ```

    The old `Fedora-Server-dvd-x86_64-39-1.5.iso` stays in `files/data/iso` and
    can be deleted to reclaim 2.5 GB.

The dnsmasq log is the single best place to watch a boot. It shows the DHCP
handshake, the bootfile handed out, and every TFTP read:

```sh
docker logs -f files-dnsmasq-1
```

A `cannot access /tftp/grubx64.efi: Permission denied` line means the extracted
tree is root-only again — dnsmasq and nginx both drop privileges. The role
normalises the mode after extraction, because AlmaLinux records that file as
`0700` inside the ISO and `xorriso` preserves it. A client that hits this falls
through to disk boot, which looks exactly like "it never tried PXE".

The node wakes on LAN, PXE boots, installs, and reboots. Then rejoin it:

```sh
ansible-playbook -i inventories/prod.yml cluster.yml --limit "$NODE"
```

!!! warning "Rebuilding metal0v2"

    `metal0v2` is `groups['masters'][0]`, which the k3s role delegates its token,
    kubeconfig and `kubectl wait` lookups to. Point them somewhere else while it
    is being rebuilt:

    ```sh
    ansible-playbook -i inventories/prod.yml cluster.yml --limit metal0v2 -e k3s_primary=metal1v2
    ```

## Post-rebuild verification

- [ ] Node is `Ready` and on the expected k3s build:

```sh
kubectl get node $NODE -o custom-columns='NODE:.metadata.name,STATUS:.status.conditions[-1].type,VERSION:.status.nodeInfo.kubeletVersion'
```

- [ ] etcd is back to six members, with a **new** random suffix for this node and
      no leftover entry for the old one:

```sh
kubectl get nodes -o custom-columns='NODE:.metadata.name,MEMBER:.metadata.annotations.etcd\.k3s\.cattle\.io/node-name'
```

- [ ] Disk came back with four partitions and both volume groups:

```sh
ssh root@$NODE lsblk
ssh root@$NODE vgs
```

- [ ] OS is patched and stays patched — this is the actual point of the project:

```sh
ssh root@$NODE "cat /etc/almalinux-release; uname -r; systemctl is-enabled dnf-automatic.timer; dnf check-update | tail -5"
```

- [ ] Ceph is whole again: `6 osds: 6 up, 6 in`, mon quorum of 3, all PGs
      `active+clean`:

```sh
ceph -s
ceph osd tree
```

- [ ] **Pass 2+ only** — the OSD was *adopted*, not recreated. The node should
      come back with its previous OSD id and no large backfill. BlueStore keeps
      its identity on the device, so Rook's provision job can re-adopt an intact
      `/dev/mapper/ceph-osd`. Check the operator log if the id changed:

```sh
kubectl -n rook-ceph logs deploy/rook-ceph-operator | grep -i -e osd -e "$NODE"
```

If it provisioned a fresh OSD instead, the cost is one backfill — the same cost
as pass 1 — so the fallback is simply to let it rebuild.

- [ ] CephFS survived the node loss: MDS is `1/1 up` with a hot standby, and the
      two MDS pods are still on different hosts.

Then move to the next node in the table. Do not start the next one until `ceph -s`
is fully `active+clean`.

## After the last node

- [ ] Drop the two legacy device names from `system/rook-ceph/values.yaml`, leaving
      only `/dev/mapper/ceph-osd`.
- [ ] Leave `cephx.csi.keyType: aes` pinned. AlmaLinux 10 ships a ~6.12 kernel and
      `aes256k` needs 7.0+, so rotating CSI keys would still break new mounts and
      the insecure-key-type `HEALTH_WARN` stays.
- [ ] Delete `metal/inventories/stag.yml` — it is dead leftover config from the
      upstream fork.
- [ ] Consider converting one node to an agent. k3s wants an **odd** number of
      servers for embedded etcd; six gives quorum 4 and tolerates only two
      failures, whereas five servers tolerate two as well and leave the sixth node
      free of etcd write load.
