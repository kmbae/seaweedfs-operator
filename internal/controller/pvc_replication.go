package controller

import (
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"

	"github.com/seaweedfs/seaweedfs/weed/storage/super_block"
)

const (
	// AnnotationPVCReplication requests filer path replication for a CSI PVC.
	// Applied via fs.configure on the volume's filer path prefix.
	AnnotationPVCReplication = "seaweed.seaweedfs.com/replication"
	// AnnotationPVCReplicationLegacy is a deprecated alias kept for early manifests.
	AnnotationPVCReplicationLegacy = "seaweed.seaweedfs.com/default-replication"
	// AnnotationPVCReplicationApplied records the last successfully applied value.
	AnnotationPVCReplicationApplied = "seaweed.seaweedfs.com/replication-applied"
	// AnnotationPVCReplicationLocation records the filer path prefix that was configured.
	AnnotationPVCReplicationLocation = "seaweed.seaweedfs.com/replication-location"
	// AnnotationPVCClusterRef overrides the default Seaweed CR as "namespace/name".
	AnnotationPVCClusterRef = "seaweed.seaweedfs.com/cluster-ref"
	// AnnotationPVCLocationPrefix overrides the filer path derived from the bound PV.
	AnnotationPVCLocationPrefix = "seaweed.seaweedfs.com/location-prefix"

	PVCReplicationFinalizer = "seaweed.seaweedfs.com/replication-cleanup"
)

// pvcReplicationFromAnnotations returns the desired replication code from PVC
// annotations, or "" when unset.
func pvcReplicationFromAnnotations(ann map[string]string) string {
	if ann == nil {
		return ""
	}
	if v := strings.TrimSpace(ann[AnnotationPVCReplication]); v != "" {
		return v
	}
	return strings.TrimSpace(ann[AnnotationPVCReplicationLegacy])
}

func validateReplication(replication string) error {
	if replication == "" {
		return fmt.Errorf("replication must not be empty")
	}
	if _, err := super_block.NewReplicaPlacementFromString(replication); err != nil {
		return fmt.Errorf("invalid replication %q: %w", replication, err)
	}
	return nil
}

func pvcMatchesStorageClass(pvc *corev1.PersistentVolumeClaim, allowed map[string]struct{}) bool {
	if len(allowed) == 0 {
		return true
	}
	sc := ""
	if pvc.Spec.StorageClassName != nil {
		sc = *pvc.Spec.StorageClassName
	}
	_, ok := allowed[sc]
	return ok
}

func parseClusterRefAnnotation(ann map[string]string, defaultNS, defaultName string) (types.NamespacedName, error) {
	ref := types.NamespacedName{Namespace: defaultNS, Name: defaultName}
	if defaultName == "" {
		return ref, fmt.Errorf("default Seaweed cluster name is not configured")
	}
	if ann == nil {
		return ref, nil
	}
	raw := strings.TrimSpace(ann[AnnotationPVCClusterRef])
	if raw == "" {
		return ref, nil
	}
	parts := strings.Split(raw, "/")
	switch len(parts) {
	case 1:
		ref.Name = parts[0]
	case 2:
		ref.Namespace = parts[0]
		ref.Name = parts[1]
	default:
		return ref, fmt.Errorf("cluster-ref %q must be \"name\" or \"namespace/name\"", raw)
	}
	if ref.Namespace == "" {
		ref.Namespace = defaultNS
	}
	if ref.Name == "" {
		return ref, fmt.Errorf("cluster-ref %q has empty Seaweed name", raw)
	}
	return ref, nil
}

// pvcLocationPrefix returns the filer path prefix for fs.configure. When the PVC
// is bound, the CSI volume handle (full filer path) is preferred. A trailing
// slash is appended so child paths inherit the rule, matching Bucket placement.
func pvcLocationPrefix(pvc *corev1.PersistentVolumeClaim, pv *corev1.PersistentVolume) (string, error) {
	if ann := pvc.Annotations; ann != nil {
		if override := strings.TrimSpace(ann[AnnotationPVCLocationPrefix]); override != "" {
			return normalizeLocationPrefix(override), nil
		}
	}
	if pv != nil && pv.Spec.CSI != nil {
		if handle := strings.TrimSpace(pv.Spec.CSI.VolumeHandle); handle != "" {
			return normalizeLocationPrefix(handle), nil
		}
	}
	if pvc.Status.Phase != corev1.ClaimBound {
		return "", fmt.Errorf("PVC is not bound yet")
	}
	return "", fmt.Errorf("bound PVC has no CSI volume handle on PV %q", pvc.Spec.VolumeName)
}

func normalizeLocationPrefix(prefix string) string {
	prefix = strings.TrimSpace(prefix)
	if prefix == "" {
		return prefix
	}
	if !strings.HasPrefix(prefix, "/") {
		prefix = "/" + prefix
	}
	if !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	return prefix
}

func storageClassSet(classes []string) map[string]struct{} {
	out := make(map[string]struct{}, len(classes))
	for _, sc := range classes {
		sc = strings.TrimSpace(sc)
		if sc != "" {
			out[sc] = struct{}{}
		}
	}
	return out
}
