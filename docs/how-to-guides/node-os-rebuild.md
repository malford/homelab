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

!!! tip "Prove the partition scheme while the OSD device is still empty"

    There is no staging cluster. The only unproven piece is the `%pre` block, so
    rebuild `metal3v2` **twice** — but do the second pass **before** letting Rook
    build its OSD, while `ceph/osd` exists and is empty.

    `%pre` branches on whether `ceph/osd` exists, so an empty LV exercises the
    same destructive-if-wrong path as a full one, at a moment when there is
    nothing on that device to lose. Building the OSD first costs a backfill in,
    a second rebuild, and possibly a backfill back out — hours, for no extra
    signal about *our* code. The one thing it would additionally test is
    `ceph-volume`'s re-adoption of a populated device, which is Rook's code with
    a bounded failure mode: a fresh OSD plus a backfill, i.e. exactly what pass 1
    costs anyway.

    So: pass 1 → pass 2 on the empty LV → confirm the UUIDs below → *then*
    restart the operator and pay one backfill.

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

If the node is already on the new layout, record the LVM identity and the
partition offsets as well:

```sh
ssh root@$NODE "lvs -o lv_name,vg_name,lv_uuid ceph; vgs -o vg_name,vg_uuid ceph; \
  pvs -o pv_name,pv_uuid,vg_name; parted -s /dev/nvme0n1 unit s print"
```

!!! important "This is the only proof that `p4` was preserved"

    A preserved `p4` and one repartitioned to the same fixed offsets look
    identical in `lsblk`. The falsifiable evidence is the UUIDs: after the
    rebuild the `p4` PV UUID, the `ceph` VG UUID and the `ceph/osd` LV UUID must
    be **unchanged**, while the `p3` PV UUID must be **new** because `%pre`
    rebuilds the OS volume group from scratch. Without this snapshot the pass-2
    result is unfalsifiable.

### 2. Take the OSD out of service

Which path you take depends on the layout the node is **currently** running, not
on which pass number you are on. Check:

```sh
ssh root@$NODE "lvs -o lv_name,vg_name"
```

| What you see | Path |
| --- | --- |
| VG `system`, LV `ceph` (or `ceph-storage`) | **Destroy** — the OSD is inside the OS volume group, so `%pre` repartitions from scratch and it cannot survive |
| VG `ceph`, LV `osd` | **Preserve** — `%pre` keeps `p4` intact and Rook re-adopts the device |

A node with no OSD at all (a rebuild that has not been given one yet) skips this
step entirely — go straight to step 3.

#### Destroy path — old layout

```sh
ceph osd out $OSD_ID
ceph -s   # repeat until all PGs are active+clean again
```

This is the long step: minutes for a small node, closer to an hour for metal0v2
or metal1v2.

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

#### Preserve path — new layout

Do **not** drain the OSD and do **not** purge it. Mark the cluster `noout` so the
OSD stays `in` while it is down, then stop the daemon:

```sh
ceph osd set noout
kubectl -n rook-ceph scale deploy rook-ceph-osd-$OSD_ID --replicas=0
ceph osd tree   # repeat until the OSD reads `down` but still `in`
```

!!! danger "Purging defeats the whole point of this path"

    `ceph osd purge` deletes the OSD's auth entity and removes its id from the
    osdmap. A BlueStore device still carrying that id can then never be
    re-activated — Rook falls back to provisioning a brand new OSD, and you pay
    the full backfill you were trying to avoid. The same goes for `ceph osd
    destroy` and `crush remove`. Leave the OSD's identity entirely alone.

!!! warning "`noout` is required, and it is a real tradeoff"

    `mon_osd_down_out_interval` defaults to **600s**, and a reimage plus rejoin
    takes longer than that. Without `noout` the OSD is marked `out` mid-rebuild
    and Ceph starts the backfill anyway.

    The cost is that every PG mapped to this OSD runs on a **single copy** for the
    ~20–30 minute window, because all four pools are `size=2`. A second host
    failure in that window loses data. The alternative is a full backfill out and
    another back in, which takes hours and leaves the cluster degraded for longer
    overall. Defensible for a homelab; make the call deliberately.

    Clear it as soon as the node is back `up` and `in`:

    ```sh
    ceph osd unset noout
    ```

### 3. Remove the node

```sh
kubectl drain $NODE --delete-emptydir-data --ignore-daemonsets --force
```

**Destroy path only** — the drain cordons the node, which is what finally stops
the operator from re-provisioning the OSD, so purge now. `ceph osd out` does not
stop the daemon, and `purge` refuses a live OSD with `EBUSY: osd.N is not
'down'`:

```sh
kubectl -n rook-ceph scale deploy rook-ceph-osd-$OSD_ID --replicas=0
ceph osd tree   # repeat until the OSD reads `down`
ceph osd purge $OSD_ID --yes-i-really-mean-it
kubectl -n rook-ceph delete deploy rook-ceph-osd-$OSD_ID
ceph osd tree   # no entry for $OSD_ID, and the host bucket is empty
```

!!! note "`purge` needs the plugin, not the shim"

    `ceph osd purge` is one of the commands the `mgr.a` keyring cannot run — it
    fails with exit 13, `EACCES: access denied: does your client key have mgr
    caps?`. Run it as `kubectl rook-ceph ceph osd purge ...` from the Mac instead.

Both paths then remove the node:

```sh
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
    minutes later, which puts its OSD device back in reach of
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

!!! note "A reimage rotates the SSH host key"

    The `ssh` checks below fail with `REMOTE HOST IDENTIFICATION HAS CHANGED!`
    until you drop the old key. Ansible is unaffected — `ansible.cfg` sets
    `host_key_checking = false`.

    ```sh
    ssh-keygen -R $NODE && ssh-keygen -R <node ip>
    ```

- [ ] Disk came back with four partitions and both volume groups, and
      `/etc/lvm/devices/system.devices` lists **both** `p3` and `p4` — RHEL 10
      gates LVM on that file, and anaconda only adds the disks it installed to,
      so a missing `p4` entry means the `%post` `lvmdevices --adddev` did not run
      and the `ceph` VG is invisible:

```sh
ssh root@$NODE "lsblk; vgs; lvs; cat /etc/lvm/devices/system.devices"
```

- [ ] **Preserve path only** — `p4` really was preserved, not rebuilt to the same
      offsets. Compare against the snapshot from step 1: the `p4` PV UUID, the
      `ceph` VG UUID and the `ceph/osd` LV UUID must be **unchanged**, and the
      `p3` PV UUID must be **new**:

```sh
ssh root@$NODE "lvs -o lv_name,vg_name,lv_uuid ceph; vgs -o vg_name,vg_uuid ceph; \
  pvs -o pv_name,pv_uuid,vg_name; parted -s /dev/nvme0n1 unit s print"
```

!!! tip "`dm-N: the capability attribute has been deprecated` is harmless"

    The kernel logs this from `drivers/md/dm-sysfs.c` whenever anything reads
    `/sys/block/dm-N/capability`, which udev and LVM rules do at every boot. It
    appears on the console during the first post-install boot and means nothing.

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

!!! bug "The operator does not notice a rejoined node"

    Observed 2026-10-18 on metal3v2: the node came back `Ready`, untainted and
    schedulable with `/dev/mapper/ceph-osd` present and listed, and Rook still
    left it with **no OSD** — `5 osds: 5 up, 5 in`, an empty host bucket at
    weight 0, and no `rook-ceph-osd-prepare-$NODE` job. The operator had not
    reconciled the CephCluster in two days. It logged the node *leaving*
    (`nodedaemon: node "$NODE" no longer exists, deleting its crash collector`)
    but nothing for the re-add, and the CephCluster's `lastHeartbeatTime` was
    stale at the same instant.

    Confirm before hunting placement causes — a `lastHeartbeatTime` older than
    the rebuild means the operator never looked:

    ```sh
    kubectl -n rook-ceph get pod -l app=rook-ceph-operator
    kubectl -n rook-ceph get cephcluster rook-ceph \
      -o jsonpath='{.status.phase}{"  "}{.status.conditions[-1].lastHeartbeatTime}{"\n"}'
    kubectl -n rook-ceph get jobs | grep osd-prepare
    ```

    Force a reconcile by restarting the operator. It is Deployment-managed so it
    self-heals, and it is not in the data path — mons, OSDs and MDS keep serving
    while it is gone:

    ```sh
    kubectl -n rook-ceph delete pod -l app=rook-ceph-operator
    ```

    Do **not** annotate the CephCluster CR to force this instead. ArgoCD manages
    that resource, so the annotation shows up as drift.

    Blast radius: a full reconcile re-runs `osd-prepare` on **all six** nodes and
    re-evaluates cephx key rotation (`enabling cephx key rotation because the
    cluster is not upgrading`). That path ran clean on 2026-10-16 under the
    current `cephx.csi.keyType: aes` pin, so it should be a no-op — but it is a
    cluster-wide reconcile, not a scoped one.

    It also recreates the `crashcollector` and `ceph-exporter` deployments that
    `nodedaemon` deleted when the node went away.

- [ ] **Preserve path only** — the OSD was *adopted*, not recreated: it comes
      back under its previous id with no large backfill, and the host bucket
      returns at its old weight. BlueStore keeps identity on the device, so the
      provision job can re-adopt an intact `/dev/mapper/ceph-osd` even though
      `/var/lib/rook` is gone:

```sh
kubectl -n rook-ceph logs deploy/rook-ceph-operator | grep -i -e osd -e "$NODE"
ceph osd unset noout
```

If it provisioned a fresh OSD instead, the cost is one backfill — the same cost
as the destroy path — so the fallback is simply to let it rebuild. Clear `noout`
either way, as soon as the OSD is back `up` and `in`.

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
