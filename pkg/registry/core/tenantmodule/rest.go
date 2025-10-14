/*
Copyright 2024 The Cozystack Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package tenantmodule

import (
	"context"
	"fmt"
	"net/http"
	"sync"
	"time"

	helmv2 "github.com/fluxcd/helm-controller/api/v2"
	metainternalversion "k8s.io/apimachinery/pkg/apis/meta/internalversion"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	fields "k8s.io/apimachinery/pkg/fields"
	labels "k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/selection"
	"k8s.io/apimachinery/pkg/util/duration"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/apiserver/pkg/endpoints/request"
	"k8s.io/apiserver/pkg/registry/rest"
	"k8s.io/client-go/dynamic"
	"k8s.io/klog/v2"

	corev1alpha1 "github.com/cozystack/cozystack/pkg/apis/core/v1alpha1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
)

// Ensure REST implements necessary interfaces
var (
	_ rest.Lister               = &REST{}
	_ rest.Getter               = &REST{}
	_ rest.Watcher              = &REST{}
	_ rest.TableConvertor       = &REST{}
	_ rest.Scoper               = &REST{}
	_ rest.SingularNameProvider = &REST{}
)

// Define constants for label filtering
const (
	TenantModuleLabelKey   = "internal.cozystack.io/tenantmodule"
	TenantModuleLabelValue = "true"
	singularName           = "tenantmodule"
)

// Define the GroupVersionResource for HelmRelease
var helmReleaseGVR = schema.GroupVersionResource{
	Group:    "helm.toolkit.fluxcd.io",
	Version:  "v2",
	Resource: "helmreleases",
}

// REST implements the RESTStorage interface for TenantModule resources
type REST struct {
	dynamicClient dynamic.Interface
	gvr           schema.GroupVersionResource
	gvk           schema.GroupVersionKind
	kindName      string
	singularName  string
}

// NewREST creates a new REST storage for TenantModule
func NewREST(dynamicClient dynamic.Interface) *REST {
	return &REST{
		dynamicClient: dynamicClient,
		gvr: schema.GroupVersionResource{
			Group:    corev1alpha1.GroupName,
			Version:  "v1alpha1",
			Resource: "tenantmodules",
		},
		gvk: schema.GroupVersion{
			Group:   corev1alpha1.GroupName,
			Version: "v1alpha1",
		}.WithKind("TenantModule"),
		kindName:     "TenantModule",
		singularName: singularName,
	}
}

// NamespaceScoped indicates whether the resource is namespaced
func (r *REST) NamespaceScoped() bool {
	return true
}

// GetSingularName returns the singular name of the resource
func (r *REST) GetSingularName() string {
	return r.singularName
}

// Get retrieves a TenantModule by converting the corresponding HelmRelease
func (r *REST) Get(ctx context.Context, name string, options *metav1.GetOptions) (runtime.Object, error) {
	namespace, err := r.getNamespace(ctx)
	if err != nil {
		klog.Errorf("Failed to get namespace: %v", err)
		return nil, err
	}

	klog.V(6).Infof("Attempting to retrieve TenantModule %s in namespace %s", name, namespace)

	// Get the corresponding HelmRelease
	hr, err := r.dynamicClient.Resource(helmReleaseGVR).Namespace(namespace).Get(ctx, name, *options)
	if err != nil {
		klog.Errorf("Error retrieving HelmRelease for TenantModule %s: %v", name, err)

		// Check if the error is a NotFound error
		if apierrors.IsNotFound(err) {
			// Return a NotFound error for the TenantModule resource instead of HelmRelease
			return nil, apierrors.NewNotFound(r.gvr.GroupResource(), name)
		}

		// For other errors, return them as-is
		return nil, err
	}

	// Check if HelmRelease has the required label
	if !r.hasTenantModuleLabel(hr) {
		klog.Errorf("HelmRelease %s does not have the required label %s=%s", name, TenantModuleLabelKey, TenantModuleLabelValue)
		// Return a NotFound error for the TenantModule resource
		return nil, apierrors.NewNotFound(r.gvr.GroupResource(), name)
	}

	// Convert HelmRelease to TenantModule
	convertedModule, err := r.ConvertHelmReleaseToTenantModule(hr)
	if err != nil {
		klog.Errorf("Conversion error from HelmRelease to TenantModule for resource %s: %v", name, err)
		return nil, fmt.Errorf("conversion error: %v", err)
	}

	// Explicitly set apiVersion and kind for TenantModule
	convertedModule.TypeMeta = metav1.TypeMeta{
		APIVersion: "core.cozystack.io/v1alpha1",
		Kind:       r.kindName,
	}

	// Convert TenantModule to unstructured format
	unstructuredModule, err := runtime.DefaultUnstructuredConverter.ToUnstructured(&convertedModule)
	if err != nil {
		klog.Errorf("Failed to convert TenantModule to unstructured for resource %s: %v", name, err)
		return nil, fmt.Errorf("failed to convert TenantModule to unstructured: %v", err)
	}

	// Explicitly set apiVersion and kind in unstructured object
	unstructuredModule["apiVersion"] = "core.cozystack.io/v1alpha1"
	unstructuredModule["kind"] = r.kindName

	klog.V(6).Infof("Successfully retrieved and converted resource %s of kind %s to unstructured", name, r.gvr.Resource)
	return &unstructured.Unstructured{Object: unstructuredModule}, nil
}

// List retrieves a list of TenantModules by converting HelmReleases
func (r *REST) List(ctx context.Context, options *metainternalversion.ListOptions) (runtime.Object, error) {
	namespace, err := r.getNamespace(ctx)
	if err != nil {
		klog.Errorf("Failed to get namespace: %v", err)
		return nil, err
	}

	klog.V(6).Infof("Attempting to list TenantModules in namespace %s with options: %v", namespace, options)

	// Get resource name from the request (if any)
	var resourceName string
	if requestInfo, ok := request.RequestInfoFrom(ctx); ok {
		resourceName = requestInfo.Name
	}

	// Initialize variables for selector mapping
	var helmFieldSelector string
	var helmLabelSelector string

	// Process field.selector
	if options.FieldSelector != nil {
		fs, err := fields.ParseSelector(options.FieldSelector.String())
		if err != nil {
			klog.Errorf("Invalid field selector: %v", err)
			return nil, fmt.Errorf("invalid field selector: %v", err)
		}
		// Check if selector is for metadata.name
		if name, exists := fs.RequiresExactMatch("metadata.name"); exists {
			// Create new field.selector for HelmRelease
			helmFieldSelector = fields.OneTermEqualSelector("metadata.name", name).String()
		} else {
			// If field.selector contains other fields, map them directly
			helmFieldSelector = fs.String()
		}
	}

	// Process label.selector - add the tenant module label requirement
	tenantModuleReq, err := labels.NewRequirement(TenantModuleLabelKey, selection.Equals, []string{TenantModuleLabelValue})
	if err != nil {
		klog.Errorf("Error creating tenant module label requirement: %v", err)
		return nil, fmt.Errorf("error creating tenant module label requirement: %v", err)
	}
	labelRequirements := []labels.Requirement{*tenantModuleReq}

	if options.LabelSelector != nil {
		ls := options.LabelSelector.String()
		parsedLabels, err := labels.Parse(ls)
		if err != nil {
			klog.Errorf("Invalid label selector: %v", err)
			return nil, fmt.Errorf("invalid label selector: %v", err)
		}
		if !parsedLabels.Empty() {
			reqs, _ := parsedLabels.Requirements()
			labelRequirements = append(labelRequirements, reqs...)
		}
	}

	helmLabelSelector = labels.NewSelector().Add(labelRequirements...).String()

	// Set ListOptions for HelmRelease with selector mapping
	metaOptions := metav1.ListOptions{
		FieldSelector: helmFieldSelector,
		LabelSelector: helmLabelSelector,
	}

	// List HelmReleases with mapped selectors
	hrList, err := r.dynamicClient.Resource(helmReleaseGVR).Namespace(namespace).List(ctx, metaOptions)
	if err != nil {
		klog.Errorf("Error listing HelmReleases: %v", err)
		return nil, err
	}

	// Initialize unstructured items array
	items := make([]unstructured.Unstructured, 0)

	// Iterate over HelmReleases and convert to TenantModules
	for _, hr := range hrList.Items {
		// Double-check the label requirement
		if !r.hasTenantModuleLabel(&hr) {
			continue
		}

		module, err := r.ConvertHelmReleaseToTenantModule(&hr)
		if err != nil {
			klog.Errorf("Error converting HelmRelease %s to TenantModule: %v", hr.GetName(), err)
			continue
		}

		// If resourceName is set, check for match
		if resourceName != "" && module.Name != resourceName {
			continue
		}

		// Apply label.selector
		if options.LabelSelector != nil {
			sel, err := labels.Parse(options.LabelSelector.String())
			if err != nil {
				klog.Errorf("Invalid label selector: %v", err)
				continue
			}
			if !sel.Matches(labels.Set(module.Labels)) {
				continue
			}
		}

		// Apply field.selector by name and namespace (if specified)
		if options.FieldSelector != nil {
			fs, err := fields.ParseSelector(options.FieldSelector.String())
			if err != nil {
				klog.Errorf("Invalid field selector: %v", err)
				continue
			}
			fieldsSet := fields.Set{
				"metadata.name":      module.Name,
				"metadata.namespace": module.Namespace,
			}
			if !fs.Matches(fieldsSet) {
				continue
			}
		}

		// Convert TenantModule to unstructured
		unstructuredModule, err := runtime.DefaultUnstructuredConverter.ToUnstructured(&module)
		if err != nil {
			klog.Errorf("Error converting TenantModule %s to unstructured: %v", module.Name, err)
			continue
		}
		items = append(items, unstructured.Unstructured{Object: unstructuredModule})
	}

	// Explicitly set apiVersion and kind in unstructured object
	moduleList := &unstructured.UnstructuredList{}
	moduleList.SetAPIVersion("core.cozystack.io/v1alpha1")
	moduleList.SetKind(r.kindName + "List")
	moduleList.SetResourceVersion(hrList.GetResourceVersion())
	moduleList.Items = items

	klog.V(6).Infof("Successfully listed %d TenantModule resources in namespace %s", len(items), namespace)
	return moduleList, nil
}

// Watch sets up a watch on HelmReleases, filters them based on tenant module label, and converts events to TenantModules
func (r *REST) Watch(ctx context.Context, options *metainternalversion.ListOptions) (watch.Interface, error) {
	namespace, err := r.getNamespace(ctx)
	if err != nil {
		klog.Errorf("Failed to get namespace: %v", err)
		return nil, err
	}

	klog.V(6).Infof("Setting up watch for TenantModules in namespace %s with options: %v", namespace, options)

	// Get request information, including resource name if specified
	var resourceName string
	if requestInfo, ok := request.RequestInfoFrom(ctx); ok {
		resourceName = requestInfo.Name
	}

	// Initialize variables for selector mapping
	var helmFieldSelector string
	var helmLabelSelector string

	// Process field.selector
	if options.FieldSelector != nil {
		fs, err := fields.ParseSelector(options.FieldSelector.String())
		if err != nil {
			klog.Errorf("Invalid field selector: %v", err)
			return nil, fmt.Errorf("invalid field selector: %v", err)
		}

		// Check if selector is for metadata.name
		if name, exists := fs.RequiresExactMatch("metadata.name"); exists {
			// Create new field.selector for HelmRelease
			helmFieldSelector = fields.OneTermEqualSelector("metadata.name", name).String()
		} else {
			// If field.selector contains other fields, map them directly
			helmFieldSelector = fs.String()
		}
	}

	// Process label.selector - add the tenant module label requirement
	tenantModuleReq, err := labels.NewRequirement(TenantModuleLabelKey, selection.Equals, []string{TenantModuleLabelValue})
	if err != nil {
		klog.Errorf("Error creating tenant module label requirement: %v", err)
		return nil, fmt.Errorf("error creating tenant module label requirement: %v", err)
	}
	labelRequirements := []labels.Requirement{*tenantModuleReq}

	if options.LabelSelector != nil {
		ls := options.LabelSelector.String()
		parsedLabels, err := labels.Parse(ls)
		if err != nil {
			klog.Errorf("Invalid label selector: %v", err)
			return nil, fmt.Errorf("invalid label selector: %v", err)
		}
		if !parsedLabels.Empty() {
			reqs, _ := parsedLabels.Requirements()
			labelRequirements = append(labelRequirements, reqs...)
		}
	}

	helmLabelSelector = labels.NewSelector().Add(labelRequirements...).String()

	// Set ListOptions for HelmRelease with selector mapping
	metaOptions := metav1.ListOptions{
		Watch:           true,
		ResourceVersion: options.ResourceVersion,
		FieldSelector:   helmFieldSelector,
		LabelSelector:   helmLabelSelector,
	}

	// Start watch on HelmRelease with mapped selectors
	helmWatcher, err := r.dynamicClient.Resource(helmReleaseGVR).Namespace(namespace).Watch(ctx, metaOptions)
	if err != nil {
		klog.Errorf("Error setting up watch for HelmReleases: %v", err)
		return nil, err
	}

	// Create a custom watcher to transform events
	customW := &customWatcher{
		resultChan: make(chan watch.Event),
		stopChan:   make(chan struct{}),
	}

	go func() {
		defer close(customW.resultChan)
		for {
			select {
			case event, ok := <-helmWatcher.ResultChan():
				if !ok {
					// The watcher has been closed, attempt to re-establish the watch
					klog.Warning("HelmRelease watcher closed, attempting to re-establish")
					// Implement retry logic or exit based on your requirements
					return
				}

				// Check if the object is a *v1.Status
				if status, ok := event.Object.(*metav1.Status); ok {
					klog.V(4).Infof("Received Status object in HelmRelease watch: %v", status.Message)
					continue // Skip processing this event
				}

				// Proceed with processing Unstructured objects
				matches, err := r.isRelevantHelmRelease(&event)
				if err != nil {
					klog.V(4).Infof("Non-critical error filtering HelmRelease event: %v", err)
					continue
				}

				if !matches {
					continue
				}

				// Convert HelmRelease to TenantModule
				module, err := r.ConvertHelmReleaseToTenantModule(event.Object.(*unstructured.Unstructured))
				if err != nil {
					klog.Errorf("Error converting HelmRelease to TenantModule: %v", err)
					continue
				}

				// Apply field.selector by name if specified
				if resourceName != "" && module.Name != resourceName {
					continue
				}

				// Apply label.selector
				if options.LabelSelector != nil {
					sel, err := labels.Parse(options.LabelSelector.String())
					if err != nil {
						klog.Errorf("Invalid label selector: %v", err)
						continue
					}
					if !sel.Matches(labels.Set(module.Labels)) {
						continue
					}
				}

				// Convert TenantModule to unstructured
				unstructuredModule, err := runtime.DefaultUnstructuredConverter.ToUnstructured(&module)
				if err != nil {
					klog.Errorf("Failed to convert TenantModule to unstructured: %v", err)
					continue
				}

				// Create watch event with TenantModule object
				moduleEvent := watch.Event{
					Type:   event.Type,
					Object: &unstructured.Unstructured{Object: unstructuredModule},
				}

				// Send event to custom watcher
				select {
				case customW.resultChan <- moduleEvent:
				case <-customW.stopChan:
					return
				case <-ctx.Done():
					return
				}

			case <-customW.stopChan:
				return
			case <-ctx.Done():
				return
			}
		}
	}()

	klog.V(6).Infof("Custom watch established successfully")
	return customW, nil
}

// customWatcher wraps the original watcher and filters/converts events
type customWatcher struct {
	resultChan chan watch.Event
	stopChan   chan struct{}
	stopOnce   sync.Once
}

// Stop terminates the watch
func (cw *customWatcher) Stop() {
	cw.stopOnce.Do(func() {
		close(cw.stopChan)
	})
}

// ResultChan returns the event channel
func (cw *customWatcher) ResultChan() <-chan watch.Event {
	return cw.resultChan
}

// isRelevantHelmRelease checks if the HelmRelease has the tenant module label
func (r *REST) isRelevantHelmRelease(event *watch.Event) (bool, error) {
	if event.Object == nil {
		return false, nil
	}

	// Check if the object is a *v1.Status
	if status, ok := event.Object.(*metav1.Status); ok {
		// Log at a less severe level or handle specific status errors if needed
		klog.V(4).Infof("Received Status object in HelmRelease watch: %v", status.Message)
		return false, nil // Not relevant for processing as a HelmRelease
	}

	// Proceed if it's an Unstructured object
	hr, ok := event.Object.(*unstructured.Unstructured)
	if !ok {
		return false, fmt.Errorf("expected Unstructured object, got %T", event.Object)
	}

	return r.hasTenantModuleLabel(hr), nil
}

// hasTenantModuleLabel checks if a HelmRelease has the required tenant module label
func (r *REST) hasTenantModuleLabel(hr *unstructured.Unstructured) bool {
	labels := hr.GetLabels()
	if labels == nil {
		return false
	}

	value, exists := labels[TenantModuleLabelKey]
	return exists && value == TenantModuleLabelValue
}

// filterInternalLabels removes internal tenant module labels from the map
func filterInternalLabels(m map[string]string) map[string]string {
	if m == nil {
		return nil
	}
	out := make(map[string]string, len(m))
	for k, v := range m {
		if k == TenantModuleLabelKey {
			continue
		}
		out[k] = v
	}
	return out
}

// getNamespace extracts the namespace from the context
func (r *REST) getNamespace(ctx context.Context) (string, error) {
	namespace, ok := request.NamespaceFrom(ctx)
	if !ok {
		err := fmt.Errorf("namespace not found in context")
		klog.Errorf(err.Error())
		return "", err
	}
	return namespace, nil
}

// ConvertHelmReleaseToTenantModule converts a HelmRelease to a TenantModule
func (r *REST) ConvertHelmReleaseToTenantModule(hr *unstructured.Unstructured) (corev1alpha1.TenantModule, error) {
	klog.V(6).Infof("Converting HelmRelease to TenantModule for resource %s", hr.GetName())

	var helmRelease helmv2.HelmRelease
	// Convert unstructured to HelmRelease struct
	err := runtime.DefaultUnstructuredConverter.FromUnstructured(hr.Object, &helmRelease)
	if err != nil {
		klog.Errorf("Error converting from unstructured to HelmRelease: %v", err)
		return corev1alpha1.TenantModule{}, err
	}

	// Convert HelmRelease struct to TenantModule struct
	module, err := r.convertHelmReleaseToTenantModule(&helmRelease)
	if err != nil {
		klog.Errorf("Error converting from HelmRelease to TenantModule: %v", err)
		return corev1alpha1.TenantModule{}, err
	}

	klog.V(6).Infof("Successfully converted HelmRelease %s to TenantModule", hr.GetName())
	return module, nil
}

// convertHelmReleaseToTenantModule implements the actual conversion logic
func (r *REST) convertHelmReleaseToTenantModule(hr *helmv2.HelmRelease) (corev1alpha1.TenantModule, error) {
	if hr == nil {
		return corev1alpha1.TenantModule{}, fmt.Errorf("HelmRelease is nil")
	}

	// Safely extract chart version, handling nil cases
	var appVersion string
	if hr.Spec.Chart != nil {
		appVersion = hr.Spec.Chart.Spec.Version
	}

	module := corev1alpha1.TenantModule{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "core.cozystack.io/v1alpha1",
			Kind:       r.kindName,
		},
		AppVersion: appVersion,
		ObjectMeta: metav1.ObjectMeta{
			Name:              hr.Name,
			Namespace:         hr.Namespace,
			UID:               hr.GetUID(),
			ResourceVersion:   hr.GetResourceVersion(),
			CreationTimestamp: hr.CreationTimestamp,
			DeletionTimestamp: hr.DeletionTimestamp,
			Labels:            filterInternalLabels(hr.Labels),
			Annotations:       hr.Annotations,
		},
		Status: corev1alpha1.TenantModuleStatus{
			Version: hr.Status.LastAttemptedRevision,
		},
	}

	var conditions []metav1.Condition
	for _, hrCondition := range hr.GetConditions() {
		if hrCondition.Type == "Ready" || hrCondition.Type == "Released" {
			conditions = append(conditions, metav1.Condition{
				LastTransitionTime: hrCondition.LastTransitionTime,
				Reason:             hrCondition.Reason,
				Message:            hrCondition.Message,
				Status:             hrCondition.Status,
				Type:               hrCondition.Type,
			})
		}
	}
	module.Status.Conditions = conditions
	return module, nil
}

// ConvertToTable implements the TableConvertor interface for displaying resources in a table format
func (r *REST) ConvertToTable(ctx context.Context, object runtime.Object, tableOptions runtime.Object) (*metav1.Table, error) {
	klog.V(6).Infof("ConvertToTable: received object of type %T", object)

	var table metav1.Table

	switch obj := object.(type) {
	case *unstructured.UnstructuredList:
		modules := make([]corev1alpha1.TenantModule, 0, len(obj.Items))
		for _, u := range obj.Items {
			var m corev1alpha1.TenantModule
			err := runtime.DefaultUnstructuredConverter.FromUnstructured(u.Object, &m)
			if err != nil {
				klog.Errorf("Failed to convert Unstructured to TenantModule: %v", err)
				continue
			}
			modules = append(modules, m)
		}
		table = r.buildTableFromTenantModules(modules)
		table.ListMeta.ResourceVersion = obj.GetResourceVersion()
	case *unstructured.Unstructured:
		var module corev1alpha1.TenantModule
		err := runtime.DefaultUnstructuredConverter.FromUnstructured(obj.UnstructuredContent(), &module)
		if err != nil {
			klog.Errorf("Failed to convert Unstructured to TenantModule: %v", err)
			return nil, fmt.Errorf("failed to convert Unstructured to TenantModule: %v", err)
		}
		table = r.buildTableFromTenantModule(module)
		table.ListMeta.ResourceVersion = obj.GetResourceVersion()
	default:
		resource := schema.GroupResource{}
		if info, ok := request.RequestInfoFrom(ctx); ok {
			resource = schema.GroupResource{Group: info.APIGroup, Resource: info.Resource}
		}
		return nil, errNotAcceptable{
			resource: resource,
			message:  "object does not implement the Object interfaces",
		}
	}

	// Handle table options
	if opt, ok := tableOptions.(*metav1.TableOptions); ok && opt != nil && opt.NoHeaders {
		table.ColumnDefinitions = nil
	}

	table.TypeMeta = metav1.TypeMeta{
		APIVersion: "meta.k8s.io/v1",
		Kind:       "Table",
	}

	klog.V(6).Infof("ConvertToTable: returning table with %d rows", len(table.Rows))
	return &table, nil
}

// buildTableFromTenantModules constructs a table from a list of TenantModules
func (r *REST) buildTableFromTenantModules(modules []corev1alpha1.TenantModule) metav1.Table {
	table := metav1.Table{
		ColumnDefinitions: []metav1.TableColumnDefinition{
			{Name: "NAME", Type: "string", Description: "Name of the TenantModule", Priority: 0},
			{Name: "READY", Type: "string", Description: "Ready status of the TenantModule", Priority: 0},
			{Name: "AGE", Type: "string", Description: "Age of the TenantModule", Priority: 0},
			{Name: "VERSION", Type: "string", Description: "Version of the TenantModule", Priority: 0},
		},
		Rows: make([]metav1.TableRow, 0, len(modules)),
	}
	now := time.Now()

	for _, module := range modules {
		row := metav1.TableRow{
			Cells:  []interface{}{module.GetName(), getReadyStatus(module.Status.Conditions), computeAge(module.GetCreationTimestamp().Time, now), getVersion(module.Status.Version)},
			Object: runtime.RawExtension{Object: &module},
		}
		table.Rows = append(table.Rows, row)
	}

	return table
}

// buildTableFromTenantModule constructs a table from a single TenantModule
func (r *REST) buildTableFromTenantModule(module corev1alpha1.TenantModule) metav1.Table {
	table := metav1.Table{
		ColumnDefinitions: []metav1.TableColumnDefinition{
			{Name: "NAME", Type: "string", Description: "Name of the TenantModule", Priority: 0},
			{Name: "READY", Type: "string", Description: "Ready status of the TenantModule", Priority: 0},
			{Name: "AGE", Type: "string", Description: "Age of the TenantModule", Priority: 0},
			{Name: "VERSION", Type: "string", Description: "Version of the TenantModule", Priority: 0},
		},
		Rows: []metav1.TableRow{},
	}
	now := time.Now()

	row := metav1.TableRow{
		Cells:  []interface{}{module.GetName(), getReadyStatus(module.Status.Conditions), computeAge(module.GetCreationTimestamp().Time, now), getVersion(module.Status.Version)},
		Object: runtime.RawExtension{Object: &module},
	}
	table.Rows = append(table.Rows, row)

	return table
}

// getVersion returns the module version or a placeholder if unknown
func getVersion(version string) string {
	if version == "" {
		return "<unknown>"
	}
	return version
}

// computeAge calculates the age of the object based on CreationTimestamp and current time
func computeAge(creationTime, currentTime time.Time) string {
	ageDuration := currentTime.Sub(creationTime)
	return duration.HumanDuration(ageDuration)
}

// getReadyStatus returns the ready status based on conditions
func getReadyStatus(conditions []metav1.Condition) string {
	for _, condition := range conditions {
		if condition.Type == "Ready" {
			switch condition.Status {
			case metav1.ConditionTrue:
				return "True"
			case metav1.ConditionFalse:
				return "False"
			default:
				return "Unknown"
			}
		}
	}
	return "Unknown"
}

// Destroy releases resources associated with REST
func (r *REST) Destroy() {
	// No additional actions needed to release resources.
}

// New creates a new instance of TenantModule
func (r *REST) New() runtime.Object {
	return &corev1alpha1.TenantModule{}
}

// NewList returns an empty list of TenantModule objects
func (r *REST) NewList() runtime.Object {
	return &corev1alpha1.TenantModuleList{}
}

// Kind returns the resource kind used for API discovery
func (r *REST) Kind() string {
	return r.gvk.Kind
}

// GroupVersionKind returns the GroupVersionKind for REST
func (r *REST) GroupVersionKind(schema.GroupVersion) schema.GroupVersionKind {
	return r.gvk
}

// errNotAcceptable indicates that the resource does not support conversion to Table
type errNotAcceptable struct {
	resource schema.GroupResource
	message  string
}

func (e errNotAcceptable) Error() string {
	return e.message
}

func (e errNotAcceptable) Status() metav1.Status {
	return metav1.Status{
		Status:  metav1.StatusFailure,
		Code:    http.StatusNotAcceptable,
		Reason:  metav1.StatusReason("NotAcceptable"),
		Message: e.Error(),
	}
}
