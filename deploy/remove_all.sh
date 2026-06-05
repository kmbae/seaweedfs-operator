#!/usr/bin/env bash
# Uninstall SeaweedFS Helm releases (reverse install order)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OPERATOR_NS="${OPERATOR_NS:-seaweedfs-operator}"
SEAWEED_NS="${SEAWEED_NS:-seaweedfs}"

helm uninstall -n "$OPERATOR_NS" seaweedfs-csi-driver 2>/dev/null || true
helm uninstall -n "$SEAWEED_NS" seaweedfs 2>/dev/null || true
helm uninstall -n "$SEAWEED_NS" seaweedfs-storage 2>/dev/null || true
helm uninstall -n "$OPERATOR_NS" seaweedfs-operator 2>/dev/null || true
helm uninstall -n "$OPERATOR_NS" seaweedfs-operator-crds 2>/dev/null || true

echo "All SeaweedFS Helm releases removed (CRDs may remain until manually deleted)."
