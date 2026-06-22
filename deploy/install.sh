#!/usr/bin/env bash
# SeaweedFS split Helm install: CRDs -> operator -> cluster -> CSI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OPERATOR_NS="${OPERATOR_NS:-seaweedfs-operator}"
SEAWEED_NS="${SEAWEED_NS:-seaweedfs}"
WAIT_OPERATOR="${WAIT_OPERATOR:-true}"

if command -v helm >/dev/null 2>&1; then
  HELM=(helm)
elif command -v microk8s >/dev/null 2>&1 && microk8s helm version >/dev/null 2>&1; then
  HELM=(microk8s helm)
else
  echo "ERROR: helm not found (install helm or use MicroK8s: microk8s enable helm3)" >&2
  exit 1
fi

if command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(kubectl)
elif command -v microk8s >/dev/null 2>&1; then
  KUBECTL=(microk8s kubectl)
else
  echo "ERROR: kubectl not found" >&2
  exit 1
fi

kctl() { "${KUBECTL[@]}" "$@"; }
helm_cmd() { "${HELM[@]}" "$@"; }

print_admin_credentials() {
  local ns=$1
  local secret_name
  secret_name=$(helm_cmd get values seaweedfs -n "$ns" -o jsonpath='{.admin.credentialsSecret.name}' 2>/dev/null || true)
  secret_name=${secret_name:-seaweedfs-admin-credentials}
  if ! kctl get secret "$secret_name" -n "$ns" &>/dev/null; then
    return 0
  fi
  local user pass cluster
  user=$(kctl get secret "$secret_name" -n "$ns" -o jsonpath='{.data.adminUser}' | base64 -d)
  pass=$(kctl get secret "$secret_name" -n "$ns" -o jsonpath='{.data.adminPassword}' | base64 -d)
  cluster=$(helm_cmd get values seaweedfs -n "$ns" -o jsonpath='{.name}' 2>/dev/null || true)
  cluster=${cluster:-seaweedfs}
  echo ""
  echo "=== SeaweedFS Admin UI credentials ==="
  echo "  URL:      http://localhost:23646"
  echo "  Forward:  kubectl port-forward -n $ns svc/${cluster}-admin 23646:23646"
  echo "  User:     $user"
  echo "  Password: $pass"
}

print_s3_credentials() {
  local ns=$1
  local s3_enabled
  s3_enabled=$(helm_cmd get values seaweedfs -n "$ns" -o jsonpath='{.filer.s3.enabled}' 2>/dev/null || true)
  if [[ "$s3_enabled" != "true" ]]; then
    return 0
  fi
  local secret_name cluster
  secret_name=$(helm_cmd get values seaweedfs -n "$ns" -o jsonpath='{.filer.s3.configSecret.name}' 2>/dev/null || true)
  secret_name=${secret_name:-seaweedfs-s3-config}
  if ! kctl get secret "$secret_name" -n "$ns" &>/dev/null; then
    return 0
  fi
  local access secret
  access=$(kctl get secret "$secret_name" -n "$ns" -o jsonpath='{.data.accessKey}' | base64 -d)
  secret=$(kctl get secret "$secret_name" -n "$ns" -o jsonpath='{.data.secretKey}' | base64 -d)
  cluster=$(helm_cmd get values seaweedfs -n "$ns" -o jsonpath='{.name}' 2>/dev/null || true)
  cluster=${cluster:-seaweedfs}
  echo ""
  echo "=== SeaweedFS S3 API credentials ==="
  echo "  Endpoint: http://localhost:8333"
  echo "  Forward:  kubectl port-forward -n $ns svc/${cluster}-filer 8333:8333"
  echo "  Access key: $access"
  echo "  Secret key: $secret"
  echo "  Example:  AWS_ACCESS_KEY_ID=$access AWS_SECRET_ACCESS_KEY=$secret aws --endpoint-url http://localhost:8333 s3 ls"
}

echo "=== 1/4 seaweedfs-operator-crds ==="
helm_cmd upgrade -i -n "$OPERATOR_NS" seaweedfs-operator-crds ./seaweedfs-operator-crds --create-namespace

echo "=== 2/4 seaweedfs-operator ==="
helm_cmd upgrade -i -n "$OPERATOR_NS" seaweedfs-operator ./seaweedfs-operator --create-namespace

if [[ "$WAIT_OPERATOR" == "true" ]]; then
  echo "Waiting for operator deployment..."
  kctl wait --for=condition=available deployment \
    -l app.kubernetes.io/name=seaweedfs-operator \
    -n "$OPERATOR_NS" --timeout=180s 2>/dev/null || \
  kctl wait --for=condition=available deployment/seaweedfs-operator \
    -n "$OPERATOR_NS" --timeout=180s || true
fi

echo "=== 3/4 seaweedfs (PV + StorageClass + Seaweed CR cluster) ==="
helm_cmd upgrade -i -n "$SEAWEED_NS" seaweedfs ./seaweedfs --create-namespace

echo "=== 4/4 seaweedfs-csi-driver ==="
helm_cmd upgrade -i -n "$OPERATOR_NS" seaweedfs-csi-driver ./seaweedfs-csi-driver --create-namespace

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

print_admin_credentials "$SEAWEED_NS"
print_s3_credentials "$SEAWEED_NS"
