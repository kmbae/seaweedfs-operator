#!/usr/bin/env bash
# SeaweedFS split Helm install: CRDs -> operator -> cluster -> CSI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OPERATOR_NS="${OPERATOR_NS:-seaweedfs-operator}"
SEAWEED_NS="${SEAWEED_NS:-seaweedfs}"
WAIT_OPERATOR="${WAIT_OPERATOR:-true}"

echo "=== 1/4 seaweedfs-operator-crds ==="
helm upgrade -i -n "$OPERATOR_NS" seaweedfs-operator-crds ./seaweedfs-operator-crds --create-namespace

echo "=== 2/4 seaweedfs-operator ==="
helm upgrade -i -n "$OPERATOR_NS" seaweedfs-operator ./seaweedfs-operator --create-namespace

if [[ "$WAIT_OPERATOR" == "true" ]]; then
  echo "Waiting for operator deployment..."
  kubectl wait --for=condition=available deployment \
    -l app.kubernetes.io/name=seaweedfs-operator \
    -n "$OPERATOR_NS" --timeout=180s 2>/dev/null || \
  kubectl wait --for=condition=available deployment/seaweedfs-operator \
    -n "$OPERATOR_NS" --timeout=180s || true
fi

echo "=== 3/4 seaweedfs (PV + StorageClass + Seaweed CR cluster) ==="
helm upgrade -i -n "$SEAWEED_NS" seaweedfs ./seaweedfs --create-namespace

echo "=== 4/4 seaweedfs-csi-driver ==="
helm upgrade -i -n "$OPERATOR_NS" seaweedfs-csi-driver ./seaweedfs-csi-driver --create-namespace

echo ""
echo "Done. Verify:"
echo "  kubectl get pods -n $OPERATOR_NS"
echo "  kubectl get pods -n $SEAWEED_NS"
echo "  kubectl get pv | grep seaweedfs"
echo "  kubectl get seaweed -n $SEAWEED_NS"
echo "  kubectl get sc seaweedfs-storage"
echo ""
echo "Add nodes: edit volumeNodes in seaweedfs/values.yaml, then run"
echo "  helm upgrade -i -n $SEAWEED_NS seaweedfs ./seaweedfs"
