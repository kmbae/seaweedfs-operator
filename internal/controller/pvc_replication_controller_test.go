package controller

import (
	"context"
	"testing"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	seaweedv1 "github.com/seaweedfs/seaweedfs-operator/api/v1"
)

func testPvcReplicationReconciler(t *testing.T, fa *fakeBucketAdmin, defaultCluster types.NamespacedName, objs ...client.Object) (*PvcReplicationReconciler, client.Client) {
	t.Helper()
	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		t.Fatalf("clientgoscheme: %v", err)
	}
	if err := seaweedv1.AddToScheme(scheme); err != nil {
		t.Fatalf("seaweedv1: %v", err)
	}
	cli := fake.NewClientBuilder().WithScheme(scheme).WithObjects(objs...).Build()
	r := &PvcReplicationReconciler{
		Client:            cli,
		Log:               logf.FromContext(context.Background()),
		Scheme:            scheme,
		Recorder:          record.NewFakeRecorder(10),
		DefaultClusterRef: defaultCluster,
		StorageClasses:    []string{"seaweedfs-storage"},
		AdminFactory: func(_, _ string, _ logr.Logger) (BucketAdmin, error) {
			return fa, nil
		},
	}
	return r, cli
}

func TestPvcReplicationFromAnnotations(t *testing.T) {
	t.Parallel()
	if got := pvcReplicationFromAnnotations(map[string]string{
		AnnotationPVCReplication: "010",
	}); got != "010" {
		t.Fatalf("primary annotation = %q", got)
	}
	if got := pvcReplicationFromAnnotations(map[string]string{
		AnnotationPVCReplicationLegacy: "001",
	}); got != "001" {
		t.Fatalf("legacy annotation = %q", got)
	}
	if got := pvcReplicationFromAnnotations(map[string]string{
		AnnotationPVCReplication:       "010",
		AnnotationPVCReplicationLegacy: "001",
	}); got != "010" {
		t.Fatalf("primary wins = %q", got)
	}
}

func TestValidateReplication(t *testing.T) {
	t.Parallel()
	if err := validateReplication("010"); err != nil {
		t.Fatalf("010: %v", err)
	}
	if err := validateReplication("bad"); err == nil {
		t.Fatal("expected error for bad replication")
	}
}

func TestPvcLocationPrefix(t *testing.T) {
	t.Parallel()
	pvc := &corev1.PersistentVolumeClaim{
		Status: corev1.PersistentVolumeClaimStatus{Phase: corev1.ClaimBound},
	}
	pv := &corev1.PersistentVolume{
		Spec: corev1.PersistentVolumeSpec{
			PersistentVolumeSource: corev1.PersistentVolumeSource{
				CSI: &corev1.CSIPersistentVolumeSource{VolumeHandle: "/buckets/pvc-abc"},
			},
		},
	}
	got, err := pvcLocationPrefix(pvc, pv)
	if err != nil || got != "/buckets/pvc-abc/" {
		t.Fatalf("prefix = %q err = %v", got, err)
	}
}

func TestPvcReplicationReconciler_AppliesOnBoundPVC(t *testing.T) {
	fa := newFakeAdmin()
	sc := "seaweedfs-storage"
	pvc := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-data",
			Namespace: "default",
			Annotations: map[string]string{
				AnnotationPVCReplication: "010",
			},
		},
		Spec: corev1.PersistentVolumeClaimSpec{
			StorageClassName: &sc,
			VolumeName:       "pv-my-data",
		},
		Status: corev1.PersistentVolumeClaimStatus{
			Phase: corev1.ClaimBound,
		},
	}
	pv := &corev1.PersistentVolume{
		ObjectMeta: metav1.ObjectMeta{Name: "pv-my-data"},
		Spec: corev1.PersistentVolumeSpec{
			PersistentVolumeSource: corev1.PersistentVolumeSource{
				CSI: &corev1.CSIPersistentVolumeSource{VolumeHandle: "/buckets/my-data"},
			},
		},
	}
	seaweed := &seaweedv1.Seaweed{
		ObjectMeta: metav1.ObjectMeta{Name: "seaweedfs", Namespace: "seaweedfs"},
		Spec:       seaweedv1.SeaweedSpec{Master: &seaweedv1.MasterSpec{Replicas: 1}},
	}
	r, _ := testPvcReplicationReconciler(t, fa, types.NamespacedName{Namespace: "seaweedfs", Name: "seaweedfs"}, seaweed, pvc, pv)

	key := types.NamespacedName{Namespace: "default", Name: "my-data"}
	for i := 0; i < 3; i++ {
		if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: key}); err != nil {
			t.Fatalf("reconcile: %v", err)
		}
	}

	if len(fa.calls) == 0 || fa.calls[0] != "Configure:/buckets/my-data/:-replication=010" {
		t.Fatalf("calls = %v", fa.calls)
	}

	var updated corev1.PersistentVolumeClaim
	if err := r.Get(context.Background(), key, &updated); err != nil {
		t.Fatalf("get pvc: %v", err)
	}
	if updated.Annotations[AnnotationPVCReplicationApplied] != "010" {
		t.Fatalf("applied annotation = %q", updated.Annotations[AnnotationPVCReplicationApplied])
	}
}

func TestPvcReplicationReconciler_SkipsOtherStorageClass(t *testing.T) {
	fa := newFakeAdmin()
	sc := "seaweedfs"
	pvc := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "vol",
			Namespace: "seaweedfs",
			Annotations: map[string]string{
				AnnotationPVCReplication: "010",
			},
		},
		Spec: corev1.PersistentVolumeClaimSpec{StorageClassName: &sc},
	}
	r, _ := testPvcReplicationReconciler(t, fa, types.NamespacedName{Namespace: "seaweedfs", Name: "seaweedfs"}, pvc)
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: types.NamespacedName{Namespace: "seaweedfs", Name: "vol"}}); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if len(fa.calls) != 0 {
		t.Fatalf("expected no admin calls, got %v", fa.calls)
	}
}
