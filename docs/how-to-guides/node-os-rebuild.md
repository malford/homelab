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
    for a few commands (`ceph osd df` returns exit 13) — use the Grafana Ceph
    boards or Prometheus for per-OSD utilisation.

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

`removeOSDsIfOutAndSafeToRemove: true` means the operator usually purges the OSD
itself once it is out and safe. Verify rather than assume, and purge by hand if
it is still listed:

```sh
ceph osd tree
ceph osd purge $OSD_ID --yes-i-really-mean-it
```

### 3. Drain and remove the node

```sh
kubectl drain $NODE --delete-emptydir-data --ignore-daemonsets --force
kubectl delete node $NODE
```

`kubectl delete node` is what triggers k3s to remove the matching etcd member.
Confirm the member count dropped to five before continuing:

```sh
kubectl get nodes -o custom-columns='NODE:.metadata.name,MEMBER:.metadata.annotations.etcd\.k3s\.cattle\.io/node-name'
```

### 4. Make it PXE boot

!!! danger "Never zap the whole disk on a node already using the new layout"

    `sgdisk --zap-all` or `wipefs -a /dev/nvme0n1` destroys `p4` and the OSD with
    it. To fall through to PXE, remove only the UEFI boot entry or the ESP — the
    `%pre` block handles the rest.

```sh
ssh root@$NODE efibootmgr                 # find the AlmaLinux/Fedora entry number
ssh root@$NODE efibootmgr -b <n> -B       # delete just that entry
ssh root@$NODE poweroff
```

Wiping the ESP (`wipefs -a /dev/nvme0n1p1`) works too and is equivalent for the
installer, since `%pre` recreates p1–p3 either way.

A full zap is acceptable **only** on a node still in the old single-VG layout,
where the OSD has already been purged in step 2.

### 5. Reinstall

From the jump box. `localhost` must stay in the `boot.yml` limit or the
`pxe_server` play is skipped and nothing serves the kickstart.

```sh
cd metal
ansible-playbook -i inventories/prod.yml boot.yml --limit "localhost,$NODE"
```

!!! note "The first run replaces the whole PXE tree"

    The jump box has served the Fedora 39 tree since early 2024. The first run
    downloads the AlmaLinux ISO (~1 GB), clears `files/data/os`, re-extracts, and
    recreates both PXE containers so they pick up the new `vmlinuz`/`initrd.img`.
    Confirm it actually switched before letting the node boot:

    ```sh
    ls roles/pxe_server/files/data/os/.extracted-from-*
    ```

    The old `Fedora-Server-dvd-x86_64-39-1.5.iso` stays in `files/data/iso` and
    can be deleted to reclaim 2.5 GB.

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
