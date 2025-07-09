package server

import (
	"encoding/json"
	"fmt"
	"strings"

	"k8s.io/kube-openapi/pkg/spec3"
	"k8s.io/kube-openapi/pkg/validation/spec"
)

// -----------------------------------------------------------------------------
// shared helpers
// -----------------------------------------------------------------------------

const (
	baseRef     = "com.github.cozystack.cozystack.pkg.apis.apps.v1alpha1.Application"
	baseListRef = baseRef + "List"
	smp         = "application/strategic-merge-patch+json"
)

func deepCopySchema(in *spec.Schema) *spec.Schema {
	if in == nil {
		return nil
	}
	b, err := json.Marshal(in)
	if err != nil {
		// Log error or panic since this is unexpected
		panic(fmt.Sprintf("failed to marshal schema: %v", err))
	}
	var out spec.Schema
	if err := json.Unmarshal(b, &out); err != nil {
		panic(fmt.Sprintf("failed to unmarshal schema: %v", err))
	}
	return &out
}

// find the object that already owns ".spec"
func findSpecContainer(s *spec.Schema) *spec.Schema {
	if s == nil {
		return nil
	}
	if len(s.Type) > 0 && s.Type.Contains("object") && s.Properties != nil {
		if _, ok := s.Properties["spec"]; ok {
			return s
		}
	}
	for _, branch := range [][]spec.Schema{s.AllOf, s.OneOf, s.AnyOf} {
		for i := range branch {
			if res := findSpecContainer(&branch[i]); res != nil {
				return res
			}
		}
	}
	return nil
}

// apply user-supplied schema; when raw == "" turn the field into a schemaless object
func patchSpec(target *spec.Schema, raw string) error {
	// ------------------------------------------------------------------
	// 1)  schema not provided → make ".spec" a fully open object
	// ------------------------------------------------------------------
	if strings.TrimSpace(raw) == "" {
		if target.Properties == nil {
			target.Properties = map[string]spec.Schema{}
		}
		prop := target.Properties["spec"]
		prop.AdditionalProperties = &spec.SchemaOrBool{
			Allows: true,
			Schema: &spec.Schema{},
		}
		target.Properties["spec"] = prop
		return nil
	}

	// ------------------------------------------------------------------
	// 2)  custom schema provided → keep / inject additionalProperties
	// ------------------------------------------------------------------
	var custom spec.Schema
	if err := json.Unmarshal([]byte(raw), &custom); err != nil {
		return err
	}

	// if user didn't specify additionalProperties, add a permissive one
	if custom.AdditionalProperties == nil {
		custom.AdditionalProperties = &spec.SchemaOrBool{
			Allows: true,
			Schema: &spec.Schema{},
		}
	}

	if target.Properties == nil {
		target.Properties = map[string]spec.Schema{}
	}
	target.Properties["spec"] = custom
	return nil
}

// -----------------------------------------------------------------------------
// OpenAPI **v3** post-processor
// -----------------------------------------------------------------------------
func buildPostProcessV3(kindSchemas map[string]string) func(*spec3.OpenAPI) (*spec3.OpenAPI, error) {

	return func(doc *spec3.OpenAPI) (*spec3.OpenAPI, error) {

		// Replace the basic "Application" schema with the user-supplied kinds.
		if doc.Components == nil {
			doc.Components = &spec3.Components{}
		}
		if doc.Components.Schemas == nil {
			doc.Components.Schemas = map[string]*spec.Schema{}
		}
		base, ok := doc.Components.Schemas[baseRef]
		if !ok {
			return doc, fmt.Errorf("base schema %q not found", baseRef)
		}
		for kind, raw := range kindSchemas {
			ref := fmt.Sprintf("%s.%s", "com.github.cozystack.cozystack.pkg.apis.apps.v1alpha1", kind)
			s := doc.Components.Schemas[ref]
			if s == nil { // first time – clone "Application"
				s = deepCopySchema(base)
				s.Extensions = map[string]interface{}{
					"x-kubernetes-group-version-kind": []interface{}{
						map[string]interface{}{
							"group": "apps.cozystack.io", "version": "v1alpha1", "kind": kind,
						},
					},
				}
				doc.Components.Schemas[ref] = s
			}
			container := findSpecContainer(s)
			if container == nil { // fallback: use the root
				container = s
			}
			if err := patchSpec(container, raw); err != nil {
				return nil, fmt.Errorf("kind %s: %w", kind, err)
			}
		}
		delete(doc.Components.Schemas, baseRef)
		delete(doc.Components.Schemas, baseListRef)

		// Disable strategic-merge-patch+json support in all PATCH operations
		for p, pi := range doc.Paths.Paths {
			if pi == nil || pi.Patch == nil || pi.Patch.RequestBody == nil {
				continue
			}
			delete(pi.Patch.RequestBody.Content, smp)

			doc.Paths.Paths[p] = pi
		}

		return doc, nil
	}
}

// -----------------------------------------------------------------------------
// OpenAPI **v2** (swagger) post-processor
// -----------------------------------------------------------------------------
func buildPostProcessV2(kindSchemas map[string]string) func(*spec.Swagger) (*spec.Swagger, error) {

	return func(sw *spec.Swagger) (*spec.Swagger, error) {

		// Replace the basic "Application" schema with the user-supplied kinds.
		defs := sw.Definitions
		base, ok := defs[baseRef]
		if !ok {
			return sw, fmt.Errorf("base schema %q not found", baseRef)
		}
		for kind, raw := range kindSchemas {
			ref := fmt.Sprintf("%s.%s", "com.github.cozystack.cozystack.pkg.apis.apps.v1alpha1", kind)
			s := deepCopySchema(&base)
			s.Extensions = map[string]interface{}{
				"x-kubernetes-group-version-kind": []interface{}{
					map[string]interface{}{
						"group": "apps.cozystack.io", "version": "v1alpha1", "kind": kind,
					},
				},
			}
			if err := patchSpec(s, raw); err != nil {
				return nil, fmt.Errorf("kind %s: %w", kind, err)
			}
			defs[ref] = *s
			// clone the List variant
			listName := ref + "List"
			listSrc := defs[baseListRef]
			listCopy := deepCopySchema(&listSrc)
			listCopy.Extensions = map[string]interface{}{
				"x-kubernetes-group-version-kind": []interface{}{
					map[string]interface{}{
						"group":   "apps.cozystack.io",
						"version": "v1alpha1",
						"kind":    kind + "List",
					},
				},
			}
			if items := listCopy.Properties["items"]; items.Items != nil && items.Items.Schema != nil {
				items.Items.Schema.Ref = spec.MustCreateRef("#/definitions/" + ref)
				listCopy.Properties["items"] = items
			}
			defs[listName] = *listCopy
		}
		delete(defs, baseRef)
		delete(defs, baseListRef)

		// Disable strategic-merge-patch+json support in all PATCH operations
		for p, op := range sw.Paths.Paths {
			if op.Patch != nil && len(op.Patch.Consumes) > 0 {
				var out []string
				for _, c := range op.Patch.Consumes {
					if c != smp {
						out = append(out, c)
					}
				}
				op.Patch.Consumes = out
				sw.Paths.Paths[p] = op
			}
		}

		return sw, nil
	}
}
