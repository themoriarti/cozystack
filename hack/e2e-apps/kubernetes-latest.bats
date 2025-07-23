#!/usr/bin/env bats

@test "Create a tenant Kubernetes control plane with latest version" {
  . hack/e2e-apps/run-kubernetes.sh
  run_kubernetes_test 'keys | sort_by(.) | .[-1]' 'test-latest-version' '59991'
}
