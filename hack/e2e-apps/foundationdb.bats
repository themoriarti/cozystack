#!/usr/bin/env bats

@test "Create DB FoundationDB" {
  name='test'
  kubectl apply -f - <<EOF
apiVersion: apps.cozystack.io/v1alpha1
kind: FoundationDB
metadata:
  name: $name
  namespace: tenant-test
spec:
  replicas: 3
  cluster:
    version: "7.3.63"
    processCounts:
      storage: 3
      stateless: -1
      cluster_controller: 1
    faultDomain:
      key: "foundationdb.org/none"
      valueFrom: "\$FDB_ZONE_ID"
  storage:
    size: "1Gi"
    storageClass: ""
  resourcesPreset: "small"
  backup:
    enabled: false
    s3:
      bucket: "s3.example.org/fdb-backups"
      endpoint: ""
      region: "us-east-1"
      credentials:
        accessKeyId: "oobaiRus9pah8PhohL1ThaeTa4UVa7gu"
        secretAccessKey: "ju3eum4dekeich9ahM1te8waeGai0oog"
    retentionPolicy: "7d"
  monitoring:
    enabled: true
  customParameters:
    - "knob_disable_posix_kernel_aio=1"
  imageType: "split"
  automaticReplacements: true
EOF
  sleep 15

  # Wait for HelmRelease to be ready
  kubectl -n tenant-test wait hr foundationdb-$name --timeout=300s --for=condition=ready

  # Wait for FoundationDBCluster to be created (name has foundationdb- prefix)
  timeout 300 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name; do sleep 15; done"

  # Wait for cluster to become available (initial reconciliation takes time - allow 5 minutes)
  timeout 300 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.databaseConfiguration.usable_regions}' | grep -q '1'; do sleep 30; done"

  # Check that storage processes are running
  timeout 300 sh -ec "until [ \$(kubectl -n tenant-test get pods -l foundationdb.org/fdb-cluster-name=foundationdb-$name,foundationdb.org/fdb-process-class=storage --field-selector=status.phase=Running --no-headers | wc -l) -eq 3 ]; do sleep 15; done"

  # Check that log processes are running (these are the stateless processes)
  timeout 300 sh -ec "until [ \$(kubectl -n tenant-test get pods -l foundationdb.org/fdb-cluster-name=foundationdb-$name,foundationdb.org/fdb-process-class=log --field-selector=status.phase=Running --no-headers | wc -l) -ge 1 ]; do sleep 15; done"

  # Check that cluster controller is running
  timeout 300 sh -ec "until [ \$(kubectl -n tenant-test get pods -l foundationdb.org/fdb-cluster-name=foundationdb-$name,foundationdb.org/fdb-process-class=cluster_controller --field-selector=status.phase=Running --no-headers | wc -l) -eq 1 ]; do sleep 15; done"

  # Check WorkloadMonitor is created and configured
  timeout 120 sh -ec "until kubectl -n tenant-test get workloadmonitor foundationdb-$name; do sleep 10; done"
  timeout 60 sh -ec "until kubectl -n tenant-test get workloadmonitor foundationdb-$name -o jsonpath='{.spec.replicas}' | grep -q '3'; do sleep 5; done"

  # Check dashboard resource map is created
  kubectl -n tenant-test get configmap foundationdb-$name-resourcemap

  # Verify cluster is healthy (check cluster status) - allow extra time for initial setup
  timeout 300 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.health.available}' | grep -q 'true'; do sleep 20; done"

  # Validate status.configured field
  timeout 60 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.configured}' | grep -q 'true'; do sleep 10; done"

  # Validate status.connectionString field exists and contains expected format
  timeout 60 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.connectionString}' | grep -q '@.*\.svc\.cozy\.local'; do sleep 10; done"

  # Validate comprehensive status.databaseConfiguration fields
  timeout 60 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.databaseConfiguration.logs}' | grep -q '3'; do sleep 10; done"
  timeout 60 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.databaseConfiguration.proxies}' | grep -q '3'; do sleep 10; done"
  timeout 60 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.databaseConfiguration.redundancy_mode}' | grep -q 'double'; do sleep 10; done"
  timeout 60 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.databaseConfiguration.resolvers}' | grep -q '1'; do sleep 10; done"
  timeout 60 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.databaseConfiguration.storage_engine}' | grep -q 'ssd-2'; do sleep 10; done"
  timeout 60 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.databaseConfiguration.usable_regions}' | grep -q '1'; do sleep 10; done"

  # Validate status.desiredProcessGroups field
  timeout 60 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.desiredProcessGroups}' | grep -q '^[0-9][0-9]*$'; do sleep 10; done"

  # Validate status.generations.reconciled field
  timeout 60 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.generations.reconciled}' | grep -q '^[0-9][0-9]*$'; do sleep 10; done"

  # Validate status.hasListenIPsForAllPods field
  timeout 60 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.hasListenIPsForAllPods}' | grep -q 'true'; do sleep 10; done"

  # Validate comprehensive status.health fields
  timeout 60 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.health.fullReplication}' | grep -q 'true'; do sleep 10; done"
  timeout 60 sh -ec "until kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name -o jsonpath='{.status.health.healthy}' | grep -q 'true'; do sleep 10; done"

  # Verify security context is applied correctly (non-root user)
  storage_pod=$(kubectl -n tenant-test get pods -l foundationdb.org/fdb-cluster-name=foundationdb-$name,foundationdb.org/fdb-process-class=storage --no-headers | head -n1 | awk '{print $1}')
  kubectl -n tenant-test get pod "$storage_pod" -o jsonpath='{.spec.containers[0].securityContext.runAsUser}' | grep -q '4059'
  kubectl -n tenant-test get pod "$storage_pod" -o jsonpath='{.spec.containers[0].securityContext.runAsGroup}' | grep -q '4059'

  # Clean up
  kubectl -n tenant-test delete foundationdb $name

  # Wait for cleanup to complete
  timeout 120 sh -ec "while kubectl -n tenant-test get foundationdbclusters.apps.foundationdb.org foundationdb-$name 2>/dev/null; do sleep 10; done"
}