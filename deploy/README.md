# SeaweedFS Helm deployment (split charts)

Install in order: **CRD → Operator → Storage → Cluster → CSI**.

## Chart layout

| Chart | Description |
|------|------|
| `seaweedfs-operator-crds` | Seaweed/Bucket CRD |
| `seaweedfs-operator` | Operator + Webhook + RBAC |
| `seaweedfs` | **PV + StorageClass + Seaweed CR** (master/volume/filer, volumeTopology, RDMA) |
| `seaweedfs-csi-driver` | CSI controller/node/mount + RDMA ConfigMap |
| `seaweedfs-storage` | (deprecated) merged into `seaweedfs` chart |

Legacy monolithic chart: `helm/` (deprecated, uses `seaweed.create` option)

## Install

```bash
cd deploy
./install.sh
```

Or manually:

```bash
helm upgrade -i -n seaweedfs-operator seaweedfs-operator-crds ./seaweedfs-operator-crds --create-namespace
helm upgrade -i -n seaweedfs-operator seaweedfs-operator ./seaweedfs-operator --create-namespace
helm upgrade -i -n seaweedfs seaweedfs ./seaweedfs --create-namespace
helm upgrade -i -n seaweedfs-operator seaweedfs-csi-driver ./seaweedfs-csi-driver --create-namespace
```

## Uninstall

```bash
./remove_all.sh
```

## Key values

- **seaweedfs** (`seaweedfs/values.yaml`): add a `volumeNodes` block, then `helm upgrade`
- **seaweedfs-csi-driver** (`seaweedfs-csi-driver/values.yaml`): `filer.address`, `kubelet.rootDir`, CSI/RDMA images

### Adding nodes

Add a block in `seaweedfs/values.yaml`:

```yaml
volumeNodes:
  gnode3:
    enabled: true
    pvName: seaweedfs-volume-pv-gnode3
    node: gnode3
    rack: rack2
    dataCenter: dc1
    capacity: 1Ti
    pvcRequest: 200Gi
    path: /Data/seaweedfs
```

```bash
# Prepare /Data/seaweedfs on gnode3 first
helm upgrade -i -n seaweedfs seaweedfs ./seaweedfs
```

A single `helm upgrade` applies PV + volumeTopology + RDMA sidecar together.

### Non-MicroK8s Kubernetes

```bash
helm upgrade -i -n seaweedfs-operator seaweedfs-csi-driver ./seaweedfs-csi-driver \
  --set kubelet.rootDir=/var/lib/kubelet
```

### RDMA / SR-IOV

Install InfiniBand SR-IOV (`sriov-ib-network`, `nvidia.com/mlnxnics`) in the cluster separately, then enable `rdma.enabled=true` in the `seaweedfs` chart.

### Two racks + manual CR

When using a sample CR instead of `seaweedfs`:

```bash
helm upgrade -i -n seaweedfs-operator seaweedfs-operator ./seaweedfs-operator --create-namespace
# PV via helm; cluster via sample CR:
kubectl apply -f ../config/samples/seaweed_v1_seaweed_two_racks_gnode.yaml
```

## Namespaces

| Release | Default namespace |
|--------|----------------|
| operator, crds, csi | `seaweedfs-operator` |
| seaweed, storage | `seaweedfs` |

Override with env vars: `OPERATOR_NS=... SEAWEED_NS=... ./install.sh`
