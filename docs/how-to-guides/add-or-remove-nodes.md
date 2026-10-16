# Add or remove nodes

Or how to scale horizontally.

!!! tip "Reinstalling an existing node?"

    Don't use this page. Follow [Rebuild a node's OS](node-os-rebuild.md), which
    covers draining the Ceph OSD, etcd member removal, and preserving the OSD
    partition across the reinstall.

## Add new nodes

!!! tip

    You can add multiple nodes at the same time

Add its details to the inventory. Every host in this cluster is in the `masters`
group — there is no `workers` group.

```diff title="metal/inventories/prod.yml"
     masters:
       hosts:
         metal5v2: {ansible_host: 192.168.5.112, mac: '6c:4b:90:5c:16:9f', disk: nvme0n1, network_interface: enp0s31f6}
+        metal6v2: {ansible_host: 192.168.5.116, mac: '00:11:22:33:44:55', disk: nvme0n1, network_interface: enp0s31f6}
```

!!! danger "Never insert a host above the current first entry"

    The k3s role anchors its token, kubeconfig and `kubectl wait` lookups to
    `k3s_primary`, which defaults to `groups['masters'][0]`. Appending is safe;
    prepending silently moves that anchor to a brand new, not-yet-installed host.

Install the OS and join the cluster:

```
make metal
```

To restrict the run to the new node, skip `make` and limit the playbooks
directly — `localhost` has to stay in the `boot.yml` limit or the PXE server play
is skipped:

```sh
cd metal
ansible-playbook -i inventories/prod.yml boot.yml --limit 'localhost,metal6v2'
ansible-playbook -i inventories/prod.yml cluster.yml --limit metal6v2
```

!!! note "Server count"

    k3s wants an **odd** number of servers for embedded etcd. Six servers give a
    quorum of 4 and tolerate only two failures. If you are adding capacity rather
    than control plane, make the new host an agent instead.

## Remove a node

!!! danger

    It is recommended to remove nodes one at a time

If the node hosts a Ceph OSD, drain it first — see
[Rebuild a node's OS](node-os-rebuild.md#2-drain-the-osd). Removing a node with
an `in` OSD leaves pools at a single copy.

Remove it from the inventory:

```diff title="metal/inventories/prod.yml"
     masters:
       hosts:
         metal4v2: {ansible_host: 192.168.5.111, mac: '6c:4b:90:5c:26:7f', disk: nvme0n1, network_interface: enp0s31f6}
-        metal5v2: {ansible_host: 192.168.5.112, mac: '6c:4b:90:5c:16:9f', disk: nvme0n1, network_interface: enp0s31f6}
```

Drain the node:

```sh
kubectl drain ${NODE_NAME} --delete-emptydir-data --ignore-daemonsets --force
```

Remove the node from the cluster. This is also what makes k3s drop the matching
etcd member, so confirm the member list shrank afterwards:

```sh
kubectl delete node ${NODE_NAME}
kubectl get nodes -o custom-columns='NODE:.metadata.name,MEMBER:.metadata.annotations.etcd\.k3s\.cattle\.io/node-name'
```

Shutdown the node:

```
ssh root@${NODE_IP} poweroff
```
