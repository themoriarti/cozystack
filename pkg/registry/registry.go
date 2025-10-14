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

package registry

import (
	genericregistry "k8s.io/apiserver/pkg/registry/generic/registry"
	"k8s.io/apiserver/pkg/registry/rest"
)

// REST is a thin wrapper around genericregistry.Store that also satisfies
// the GroupVersionKindProvider interface if callers need it later.
type REST struct {
	*genericregistry.Store
}

// RESTInPeace is a tiny helper so the call-site code reads nicely.  It simply
// returns its argument, letting us defer (and centralise) any future error
// handling here.
func RESTInPeace(storage rest.Storage) rest.Storage { return storage }
