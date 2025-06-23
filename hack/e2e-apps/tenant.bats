#!/usr/bin/env bats

@test "Create tenant with isolated mode enabled" {
  kubectl -n tenant-root get tenants.apps.cozystack.io test || 
  kubectl create -f - <<EOF
apiVersion: apps.cozystack.io/v1alpha1
kind: Tenant
metadata:
  name: test
  namespace: tenant-root
spec:
  etcd: false
  host: ""
  ingress: false
  isolated: true
  monitoring: false
  resourceQuotas: {}
  seaweedfs: false
EOF
  kubectl wait hr/tenant-test -n tenant-root --timeout=1m --for=condition=ready
  kubectl wait namespace tenant-test --timeout=20s --for=jsonpath='{.status.phase}'=Active
}
