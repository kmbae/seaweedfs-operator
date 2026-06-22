package controller

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	seaweedv1 "github.com/seaweedfs/seaweedfs-operator/api/v1"
)

const pvcReplicationRequeue = 15 * time.Second

// PvcReplicationReconciler applies per-PVC replication via filer fs.configure.
// It targets CSI PVCs (storageClass seaweedfs-storage by default) so master
// defaultReplication can stay at 000 while individual volumes use 010, etc.
type PvcReplicationReconciler struct {
	client.Client
	Log      logr.Logger
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder

	AdminFactory BucketAdminFactory

	// DefaultClusterRef is used when the PVC has no cluster-ref annotation.
	DefaultClusterRef types.NamespacedName
	// StorageClasses limits reconciliation to these StorageClass names.
	StorageClasses []string

	adminCache map[string]BucketAdmin
	adminMu    sync.Mutex
}

// +kubebuilder:rbac:groups="",resources=persistentvolumeclaims,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups="",resources=persistentvolumes,verbs=get;list;watch
// +kubebuilder:rbac:groups=seaweed.seaweedfs.com,resources=seaweeds,verbs=get;list;watch

func (r *PvcReplicationReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := r.Log.WithValues("pvc", req.NamespacedName)

	var pvc corev1.PersistentVolumeClaim
	if err := r.Get(ctx, req.NamespacedName, &pvc); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	allowed := storageClassSet(r.StorageClasses)
	if !pvcMatchesStorageClass(&pvc, allowed) {
		return ctrl.Result{}, nil
	}

	desired := pvcReplicationFromAnnotations(pvc.Annotations)
	applied := strings.TrimSpace(pvc.Annotations[AnnotationPVCReplicationApplied])
	appliedLoc := strings.TrimSpace(pvc.Annotations[AnnotationPVCReplicationLocation])

	if !pvc.DeletionTimestamp.IsZero() {
		return r.handleDeletion(ctx, &pvc, appliedLoc, log)
	}

	if desired == "" {
		if applied != "" || controllerutil.ContainsFinalizer(&pvc, PVCReplicationFinalizer) {
			return r.clearReplication(ctx, &pvc, appliedLoc, log)
		}
		return ctrl.Result{}, nil
	}

	if err := validateReplication(desired); err != nil {
		r.Recorder.Eventf(&pvc, corev1.EventTypeWarning, "InvalidReplication", "%v", err)
		return ctrl.Result{}, nil
	}

	clusterRef, err := parseClusterRefAnnotation(pvc.Annotations, r.DefaultClusterRef.Namespace, r.DefaultClusterRef.Name)
	if err != nil {
		r.Recorder.Eventf(&pvc, corev1.EventTypeWarning, "InvalidClusterRef", "%v", err)
		return ctrl.Result{}, nil
	}

	var seaweed seaweedv1.Seaweed
	if err := r.Get(ctx, clusterRef, &seaweed); err != nil {
		if apierrors.IsNotFound(err) {
			r.Recorder.Eventf(&pvc, corev1.EventTypeWarning, "ClusterNotFound",
				"Seaweed %s/%s not found", clusterRef.Namespace, clusterRef.Name)
			return ctrl.Result{RequeueAfter: pvcReplicationRequeue}, nil
		}
		return ctrl.Result{}, err
	}

	if pvc.Status.Phase != corev1.ClaimBound {
		log.V(1).Info("waiting for PVC to bind before applying replication")
		return ctrl.Result{RequeueAfter: pvcReplicationRequeue}, nil
	}

	var pv corev1.PersistentVolume
	if pvc.Spec.VolumeName != "" {
		if err := r.Get(ctx, types.NamespacedName{Name: pvc.Spec.VolumeName}, &pv); err != nil && !apierrors.IsNotFound(err) {
			return ctrl.Result{}, err
		}
	}

	location, err := pvcLocationPrefix(&pvc, &pv)
	if err != nil {
		log.V(1).Info("location prefix not ready", "reason", err.Error())
		return ctrl.Result{RequeueAfter: pvcReplicationRequeue}, nil
	}

	if applied == desired && appliedLoc == location {
		if !controllerutil.ContainsFinalizer(&pvc, PVCReplicationFinalizer) {
			return r.ensureFinalizer(ctx, &pvc)
		}
		return ctrl.Result{}, nil
	}

	masters := getMasterPeersString(&seaweed)
	filer := getFilerAddress(&seaweed)
	admin, err := r.getAdmin(clusterRef.Namespace, clusterRef.Name, masters, filer, log)
	if err != nil {
		return ctrl.Result{}, err
	}

	if err := admin.Configure(ctx, location, []string{"-replication=" + desired}); err != nil {
		r.Recorder.Eventf(&pvc, corev1.EventTypeWarning, "ConfigureFailed", "fs.configure failed: %v", err)
		return ctrl.Result{RequeueAfter: pvcReplicationRequeue}, nil
	}

	patch := client.MergeFrom(pvc.DeepCopy())
	if pvc.Annotations == nil {
		pvc.Annotations = map[string]string{}
	}
	pvc.Annotations[AnnotationPVCReplicationApplied] = desired
	pvc.Annotations[AnnotationPVCReplicationLocation] = location
	controllerutil.AddFinalizer(&pvc, PVCReplicationFinalizer)
	if err := r.Patch(ctx, &pvc, patch); err != nil {
		return ctrl.Result{}, err
	}

	r.Recorder.Eventf(&pvc, corev1.EventTypeNormal, "ReplicationApplied",
		"applied replication %s on %s", desired, location)
	log.Info("applied PVC replication", "replication", desired, "location", location)
	return ctrl.Result{}, nil
}

func (r *PvcReplicationReconciler) handleDeletion(ctx context.Context, pvc *corev1.PersistentVolumeClaim, location string, log logr.Logger) (ctrl.Result, error) {
	if !controllerutil.ContainsFinalizer(pvc, PVCReplicationFinalizer) {
		return ctrl.Result{}, nil
	}
	if location != "" {
		if err := r.deleteLocationConf(ctx, pvc, location, log); err != nil {
			return ctrl.Result{RequeueAfter: pvcReplicationRequeue}, nil
		}
	}
	patch := client.MergeFrom(pvc.DeepCopy())
	controllerutil.RemoveFinalizer(pvc, PVCReplicationFinalizer)
	delete(pvc.Annotations, AnnotationPVCReplicationApplied)
	delete(pvc.Annotations, AnnotationPVCReplicationLocation)
	if err := r.Patch(ctx, pvc, patch); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}

func (r *PvcReplicationReconciler) clearReplication(ctx context.Context, pvc *corev1.PersistentVolumeClaim, location string, log logr.Logger) (ctrl.Result, error) {
	if location != "" {
		if err := r.deleteLocationConf(ctx, pvc, location, log); err != nil {
			return ctrl.Result{RequeueAfter: pvcReplicationRequeue}, nil
		}
	}
	patch := client.MergeFrom(pvc.DeepCopy())
	delete(pvc.Annotations, AnnotationPVCReplicationApplied)
	delete(pvc.Annotations, AnnotationPVCReplicationLocation)
	controllerutil.RemoveFinalizer(pvc, PVCReplicationFinalizer)
	if err := r.Patch(ctx, pvc, patch); err != nil {
		return ctrl.Result{}, err
	}
	r.Recorder.Event(pvc, corev1.EventTypeNormal, "ReplicationRemoved", "removed path-specific replication")
	return ctrl.Result{}, nil
}

func (r *PvcReplicationReconciler) deleteLocationConf(ctx context.Context, pvc *corev1.PersistentVolumeClaim, location string, log logr.Logger) error {
	clusterRef, err := parseClusterRefAnnotation(pvc.Annotations, r.DefaultClusterRef.Namespace, r.DefaultClusterRef.Name)
	if err != nil {
		return err
	}
	var seaweed seaweedv1.Seaweed
	if err := r.Get(ctx, clusterRef, &seaweed); err != nil {
		return err
	}
	masters := getMasterPeersString(&seaweed)
	filer := getFilerAddress(&seaweed)
	admin, err := r.getAdmin(clusterRef.Namespace, clusterRef.Name, masters, filer, log)
	if err != nil {
		return err
	}
	if err := admin.Configure(ctx, location, []string{"-delete"}); err != nil {
		r.Recorder.Eventf(pvc, corev1.EventTypeWarning, "ConfigureDeleteFailed", "fs.configure -delete failed: %v", err)
		return fmt.Errorf("delete fs.configure for %s: %w", location, err)
	}
	return nil
}

func (r *PvcReplicationReconciler) ensureFinalizer(ctx context.Context, pvc *corev1.PersistentVolumeClaim) (ctrl.Result, error) {
	patch := client.MergeFrom(pvc.DeepCopy())
	controllerutil.AddFinalizer(pvc, PVCReplicationFinalizer)
	if err := r.Patch(ctx, pvc, patch); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{Requeue: true}, nil
}

func (r *PvcReplicationReconciler) getAdmin(ns, name, masters, filer string, log logr.Logger) (BucketAdmin, error) {
	key := ns + "/" + name + "@" + masters + "|" + filer
	r.adminMu.Lock()
	defer r.adminMu.Unlock()
	if r.adminCache == nil {
		r.adminCache = make(map[string]BucketAdmin)
	}
	if a, ok := r.adminCache[key]; ok {
		return a, nil
	}
	factory := r.AdminFactory
	if factory == nil {
		factory = NewSwadminBucketAdmin
	}
	a, err := factory(masters, filer, log)
	if err != nil {
		return nil, err
	}
	r.adminCache[key] = a
	return a, nil
}

func (r *PvcReplicationReconciler) SetupWithManager(mgr ctrl.Manager) error {
	if r.AdminFactory == nil {
		r.AdminFactory = NewSwadminBucketAdmin
	}
	return ctrl.NewControllerManagedBy(mgr).
		For(&corev1.PersistentVolumeClaim{}).
		Complete(r)
}
