package controller

import (
	"context"
	"strings"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	cozyv1alpha1 "github.com/cozystack/cozystack/api/v1alpha1"
)

// WorkloadMonitorReconciler reconciles a WorkloadMonitor object
type WorkloadReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

func (r *WorkloadReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)
	w := &cozyv1alpha1.Workload{}
	err := r.Get(ctx, req.NamespacedName, w)
	if err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		logger.Error(err, "Unable to fetch Workload")
		return ctrl.Result{}, err
	}

	// it's being deleted, nothing to handle
	if w.DeletionTimestamp != nil {
		return ctrl.Result{}, nil
	}

	t := getMonitoredObject(w)

	if t == nil {
		err = r.Delete(ctx, w)
		if err != nil {
			logger.Error(err, "failed to delete workload")
		}
		return ctrl.Result{}, err
	}

	err = r.Get(ctx, types.NamespacedName{Name: t.GetName(), Namespace: t.GetNamespace()}, t)

	// found object, nothing to do
	if err == nil {
		return ctrl.Result{}, nil
	}

	// error getting object but not 404 -- requeue
	if !apierrors.IsNotFound(err) {
		logger.Error(err, "failed to get dependent object", "kind", t.GetObjectKind(), "dependent-object-name", t.GetName())
		return ctrl.Result{}, err
	}

	err = r.Delete(ctx, w)
	if err != nil {
		logger.Error(err, "failed to delete workload")
	}
	return ctrl.Result{}, err
}

// SetupWithManager registers our controller with the Manager and sets up watches.
func (r *WorkloadReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		// Watch WorkloadMonitor objects
		For(&cozyv1alpha1.Workload{}).
		Complete(r)
}

func getMonitoredObject(w *cozyv1alpha1.Workload) client.Object {
	switch {
	case strings.HasPrefix(w.Name, "pvc-"):
		obj := &corev1.PersistentVolumeClaim{}
		obj.Name = strings.TrimPrefix(w.Name, "pvc-")
		obj.Namespace = w.Namespace
		return obj
	case strings.HasPrefix(w.Name, "svc-"):
		obj := &corev1.Service{}
		obj.Name = strings.TrimPrefix(w.Name, "svc-")
		obj.Namespace = w.Namespace
		return obj
	case strings.HasPrefix(w.Name, "pod-"):
		obj := &corev1.Pod{}
		obj.Name = strings.TrimPrefix(w.Name, "pod-")
		obj.Namespace = w.Namespace
		return obj
	}
	var obj client.Object
	return obj
}
