package lineagecontrollerwebhook

import (
	"bytes"
	"text/template"

	cozyv1alpha1 "github.com/cozystack/cozystack/api/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
)

// matchName checks if the provided name matches any of the resource names in the array.
// Each entry in resourceNames is treated as a Go template that gets rendered using the passed context.
// A nil resourceNames array matches any string.
func matchName(name string, context map[string]string, resourceNames []string) bool {
	if resourceNames == nil {
		return true
	}

	for _, templateStr := range resourceNames {
		tmpl, err := template.New("resourceName").Parse(templateStr)
		if err != nil {
			// TODO: emit warning if error
			continue
		}

		var buf bytes.Buffer
		err = tmpl.Execute(&buf, context)
		if err != nil {
			// TODO: emit warning if error
			continue
		}

		if buf.String() == name {
			return true
		}
	}

	return false
}

func matchResourceToSelector(name string, ctx, l map[string]string, s *cozyv1alpha1.CozystackResourceDefinitionResourceSelector) bool {
	// TODO: emit warning if error
	sel, err := metav1.LabelSelectorAsSelector(&s.LabelSelector)
	if err != nil {
		return false
	}
	labelMatches := sel.Matches(labels.Set(l))
	nameMatches := matchName(name, ctx, s.ResourceNames)
	return labelMatches && nameMatches
}

func matchResourceToSelectorArray(name string, ctx, l map[string]string, ss []*cozyv1alpha1.CozystackResourceDefinitionResourceSelector) bool {
	for _, s := range ss {
		if matchResourceToSelector(name, ctx, l, s) {
			return true
		}
	}
	return false
}

func matchResourceToExcludeInclude(name string, ctx, l map[string]string, ex, in []*cozyv1alpha1.CozystackResourceDefinitionResourceSelector) bool {
	if matchResourceToSelectorArray(name, ctx, l, ex) {
		return false
	}
	if matchResourceToSelectorArray(name, ctx, l, in) {
		return true
	}
	return false
}
