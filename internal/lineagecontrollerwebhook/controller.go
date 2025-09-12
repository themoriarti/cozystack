package lineagecontrollerwebhook

import (
	"context"

	cozyv1alpha1 "github.com/cozystack/cozystack/api/v1alpha1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

// +kubebuilder:rbac:groups=cozystack.io,resources=cozystackresourcedefinitions,verbs=list;watch

func (c *LineageControllerWebhook) SetupWithManagerAsController(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&cozyv1alpha1.CozystackResourceDefinition{}).
		Complete(c)
}

func (c *LineageControllerWebhook) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	l := log.FromContext(ctx)
	crds := &cozyv1alpha1.CozystackResourceDefinitionList{}
	if err := c.List(ctx, crds, &client.ListOptions{Namespace: "cozy-system"}); err != nil {
		l.Error(err, "failed reading CozystackResourceDefinitions")
		return ctrl.Result{}, err
	}
	newConfig := make(map[chartRef]appRef)
	for _, crd := range crds.Items {
		k := chartRef{
			crd.Spec.Release.Chart.SourceRef.Name,
			crd.Spec.Release.Chart.Name,
		}
		newRef := appRef{"apps.cozystack.io/v1alpha1", crd.Spec.Application.Kind, crd.Spec.Release.Prefix}
		if oldRef, exists := newConfig[k]; exists {
			l.Info("duplicate chart mapping detected; ignoring subsequent entry", "key", k, "retained value", oldRef, "ignored value", newRef)
			continue
		}
		newConfig[k] = newRef
	}
	c.config.Store(&runtimeConfig{newConfig})
	return ctrl.Result{}, nil
}
