#!/usr/bin/env bats

@test "Create a tenant Kubernetes control plane" {
  LATEST_K8S_VERSION=$(yq 'keys | .[-1]' ../packages/apps/kubernetes/files/versions.yaml)
  TEMPORAL_TENANT_PORT=59991

  kubectl apply -f - <<EOF
apiVersion: apps.cozystack.io/v1alpha1
kind: Kubernetes
metadata:
  name: test-latest
  namespace: tenant-test
spec:
  addons:
    certManager:
      enabled: false
      valuesOverride: {}
    cilium:
      valuesOverride: {}
    fluxcd:
      enabled: false
      valuesOverride: {}
    gatewayAPI:
      enabled: false
    gpuOperator:
      enabled: false
      valuesOverride: {}
    ingressNginx:
      enabled: true
      hosts: []
      valuesOverride: {}
    monitoringAgents:
      enabled: false
      valuesOverride: {}
    verticalPodAutoscaler:
      valuesOverride: {}
  controlPlane:
    apiServer:
      resources: {}
      resourcesPreset: small
    controllerManager:
      resources: {}
      resourcesPreset: micro
    konnectivity:
      server:
        resources: {}
        resourcesPreset: micro
    replicas: 2
    scheduler:
      resources: {}
      resourcesPreset: micro
  host: ""
  nodeGroups:
    md0:
      ephemeralStorage: 20Gi
      gpus: []
      instanceType: u1.medium
      maxReplicas: 10
      minReplicas: 0
      resources:
        cpu: ""
        memory: ""
      roles:
      - ingress-nginx
  storageClass: replicated
  version: "$LATEST_K8S_VERSION"
EOF
  # Wait for the tenant-test namespace to be active
  kubectl wait namespace tenant-test --timeout=20s --for=jsonpath='{.status.phase}'=Active
  
  # Wait for the Kamaji control plane to be created (retry for up to 10 seconds)
  timeout 10 sh -ec 'until kubectl get kamajicontrolplane -n tenant-test kubernetes-test-latest; do sleep 1; done'

  # Wait for the tenant control plane to be fully created (timeout after 4 minutes)
  kubectl wait --for=condition=TenantControlPlaneCreated kamajicontrolplane -n tenant-test kubernetes-test-latest --timeout=4m
  
  # Wait for Kubernetes resources to be ready (timeout after 2 minutes)
  kubectl wait tcp -n tenant-test kubernetes-test-latest --timeout=2m --for=jsonpath='{.status.kubernetesResources.version.status}'=Ready
  
  # Wait for all required deployments to be available (timeout after 4 minutes)
  kubectl wait deploy --timeout=4m --for=condition=available -n tenant-test kubernetes-test-latest kubernetes-test-latest-cluster-autoscaler kubernetes-test-latest-kccm kubernetes-test-latest-kcsi-controller
  
  # Wait for the machine deployment to scale to 2 replicas (timeout after 1 minute)
  kubectl wait machinedeployment kubernetes-test-latest-md0 -n tenant-test --timeout=1m --for=jsonpath='{.status.replicas}'=2

  # Get the admin kubeconfig and save it to a file
  kubectl get secret kubernetes-test-latest-admin-kubeconfig -ojsonpath='{.data.super-admin\.conf}' -n tenant-test | base64 -d > tenantkubeconfig

  # Update the kubeconfig to use localhost for the API server
  yq -i ".clusters[0].cluster.server = \"https://localhost:${TEMPORAL_TENANT_PORT}\"" tenantkubeconfig

  # Set up port forwarding to the Kubernetes API server for a 40 second timeout
  bash -c 'timeout 40s kubectl port-forward service/kubernetes-test-latest -n tenant-test '"${TEMPORAL_TENANT_PORT}"':6443 > /dev/null 2>&1 &'

  # Verify the Kubernetes version matches what we expect (retry for up to 20 seconds)
  timeout 20 sh -ec 'until kubectl --kubeconfig tenantkubeconfig version 2>/dev/null | grep "Server Version: $LATEST_K8S_VERSION"; do sleep 5; done'

  # Wait for all machine deployment replicas to be ready (timeout after 10 minutes)
  kubectl wait machinedeployment kubernetes-test-latest-md0 -n tenant-test --timeout=10m --for=jsonpath='{.status.v1beta2.readyReplicas}'=2

  # Clean up by deleting the Kubernetes resource
  kubectl -n tenant-test delete kuberneteses.apps.cozystack.io test-latest
}
