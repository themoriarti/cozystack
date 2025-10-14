package dashboard

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	dashv1alpha1 "github.com/cozystack/cozystack/api/dashboard/v1alpha1"
	cozyv1alpha1 "github.com/cozystack/cozystack/api/v1alpha1"

	apiextv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

// ensureCustomColumnsOverride creates or updates a CustomColumnsOverride that
// renders a header row with a colored badge and resource name link, plus a few
// useful columns (Ready, Created, Version).
//
// Naming convention mirrors your example:
//
//	metadata.name: stock-namespace-<group>.<version>.<plural>
//	spec.id:       stock-namespace-/<group>/<version>/<plural>
func (m *Manager) ensureCustomColumnsOverride(ctx context.Context, crd *cozyv1alpha1.CozystackResourceDefinition) (controllerutil.OperationResult, error) {
	g, v, kind := pickGVK(crd)
	plural := pickPlural(kind, crd)
	// Details page segment uses lowercase kind, mirroring your example
	detailsSegment := strings.ToLower(kind) + "-details"

	name := fmt.Sprintf("stock-namespace-%s.%s.%s", g, v, plural)
	id := fmt.Sprintf("stock-namespace-/%s/%s/%s", g, v, plural)

	// Badge content & color derived from kind
	badgeText := initialsFromKind(kind) // e.g., "VirtualMachine" -> "VM", "Bucket" -> "B"
	badgeColor := hexColorForKind(kind) // deterministic, dark enough for white text

	obj := &dashv1alpha1.CustomColumnsOverride{}
	obj.SetName(name)

	href := fmt.Sprintf("/openapi-ui/{2}/{reqsJsonPath[0]['.metadata.namespace']['-']}/factory/%s/{reqsJsonPath[0]['.metadata.name']['-']}", detailsSegment)
	if g == "apps.cozystack.io" && kind == "Tenant" && plural == "tenants" {
		href = "/openapi-ui/{2}/{reqsJsonPath[0]['.status.namespace']['-']}/api-table/core.cozystack.io/v1alpha1/tenantmodules"
	}

	desired := map[string]any{
		"spec": map[string]any{
			"id": id,
			"additionalPrinterColumns": []any{
				map[string]any{
					"name":     "Name",
					"type":     "factory",
					"jsonPath": ".metadata.name",
					"customProps": map[string]any{
						"disableEventBubbling": true,
						"items": []any{
							map[string]any{
								"type": "antdFlex",
								"data": map[string]any{
									"id":    "header-row",
									"align": "center",
									"gap":   6,
								},
								"children": []any{
									map[string]any{
										"type": "antdText",
										"data": map[string]any{
											"id":    "header-badge",
											"text":  badgeText,
											"title": strings.ToLower(kind), // optional tooltip
											"style": map[string]any{
												"backgroundColor": badgeColor,
												"borderRadius":    "20px",
												"color":           "#fff",
												"display":         "inline-block",
												"fontFamily":      "RedHatDisplay, Overpass, overpass, helvetica, arial, sans-serif",
												"fontSize":        "15px",
												"fontWeight":      400,
												"lineHeight":      "24px",
												"minWidth":        24,
												"padding":         "0 9px",
												"textAlign":       "center",
												"whiteSpace":      "nowrap",
											},
										},
									},
									map[string]any{
										"type": "antdLink",
										"data": map[string]any{
											"id":   "name-link",
											"text": "{reqsJsonPath[0]['.metadata.name']['-']}",
											"href": href,
										},
									},
								},
							},
						},
					},
				},
				map[string]any{
					"name":     "Ready",
					"type":     "Boolean",
					"jsonPath": `.status.conditions[?(@.type=="Ready")].status`,
				},
				map[string]any{
					"name":     "Created",
					"type":     "factory",
					"jsonPath": ".metadata.creationTimestamp",
					"customProps": map[string]any{
						"disableEventBubbling": true,
						"items": []any{
							map[string]any{
								"type": "antdFlex",
								"data": map[string]any{
									"id":    "time-block",
									"align": "center",
									"gap":   6,
								},
								"children": []any{
									map[string]any{
										"type": "antdText",
										"data": map[string]any{
											"id":   "time-icon",
											"text": "🌐",
										},
									},
									map[string]any{
										"type": "parsedText",
										"data": map[string]any{
											"id":        "time-value",
											"text":      "{reqsJsonPath[0]['.metadata.creationTimestamp']['-']}",
											"formatter": "timestamp",
										},
									},
								},
							},
						},
					},
				},
				map[string]any{
					"name":     "Version",
					"type":     "string",
					"jsonPath": ".status.version",
				},
			},
		},
	}

	_, err := controllerutil.CreateOrUpdate(ctx, m.client, obj, func() error {
		if err := controllerutil.SetOwnerReference(crd, obj, m.scheme); err != nil {
			return err
		}
		// Add dashboard labels to dynamic resources
		m.addDashboardLabels(obj, crd, ResourceTypeDynamic)
		b, err := json.Marshal(desired["spec"])
		if err != nil {
			return err
		}

		// Only update spec if it's different to avoid unnecessary updates
		newSpec := dashv1alpha1.ArbitrarySpec{JSON: apiextv1.JSON{Raw: b}}
		if !compareArbitrarySpecs(obj.Spec, newSpec) {
			obj.Spec = newSpec
		}
		return nil
	})
	// Return OperationResultCreated/Updated is not available here with unstructured; we can mimic Updated when no error.
	return controllerutil.OperationResultNone, err
}
