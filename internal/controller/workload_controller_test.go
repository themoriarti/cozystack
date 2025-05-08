package controller

import (
	"testing"

	cozyv1alpha1 "github.com/cozystack/cozystack/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
)

func TestUnprefixedMonitoredObjectReturnsNil(t *testing.T) {
	w := &cozyv1alpha1.Workload{}
	w.Name = "unprefixed-name"
	obj := getMonitoredObject(w)
	if obj != nil {
		t.Errorf(`getMonitoredObject(&Workload{Name: "%s"}) == %v, want nil`, w.Name, obj)
	}
}

func TestPodMonitoredObject(t *testing.T) {
	w := &cozyv1alpha1.Workload{}
	w.Name = "pod-mypod"
	obj := getMonitoredObject(w)
	if pod, ok := obj.(*corev1.Pod); !ok || pod.Name != "mypod" {
		t.Errorf(`getMonitoredObject(&Workload{Name: "%s"}) == %v, want &Pod{Name: "mypod"}`, w.Name, obj)
	}
}
