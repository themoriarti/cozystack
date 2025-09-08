package lineagecontrollerwebhook

import (
	"fmt"

	helmv2 "github.com/fluxcd/helm-controller/api/v2"
)

type chartRef struct {
	repo  string
	chart string
}

type appRef struct {
	groupVersion string
	kind         string
	prefix       string
}

type runtimeConfig struct {
	chartAppMap map[chartRef]appRef
}

func (l *LineageControllerWebhook) initConfig() {
	l.initOnce.Do(func() {
		if l.config.Load() == nil {
			l.config.Store(&runtimeConfig{chartAppMap: make(map[chartRef]appRef)})
		}
	})
}

func (l *LineageControllerWebhook) Map(hr *helmv2.HelmRelease) (string, string, string, error) {
	cfg := l.config.Load().(*runtimeConfig).chartAppMap
	s := &hr.Spec.Chart.Spec
	val, ok := cfg[chartRef{s.SourceRef.Name, s.Chart}]
	if !ok {
		return "", "", "", fmt.Errorf("cannot map helm release %s/%s to dynamic app", hr.Namespace, hr.Name)
	}
	return val.groupVersion, val.kind, val.prefix, nil
}
