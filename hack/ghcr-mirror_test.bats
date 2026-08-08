#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Unit tests for the in-sandbox ghcr.io pull-through mirror (cozystack/cozystack#3513).
#
# hack/e2e-ghcr-mirror.yaml bundles Service + Deployment + CiliumClusterwideNetworkPolicy
# but they apply in two phases, exactly like the talos-image-cache manifest:
# hack/e2e-install-cozystack.bats applies everything EXCEPT the Cilium policy (its CRD
# does not exist before Cozystack is installed), and hack/e2e-chainsaw/_lib/ghcr-mirror.sh
# applies ONLY that policy later once Cilium is up. These tests pin that split, the
# egress selector/target identities the allow depends on, the pull-through config, and
# the one pure string fragment (ghcr_registry_mirrors_block) whose indentation decides
# whether tenant CRs render at all. The kubectl orchestration around it needs a live
# cluster and is covered by the e2e run, matching the other hack/ helpers.
#
# cozytest.sh's awk parser recognizes only @test blocks and a bare `}` on its own line;
# there is no bats `run`/`$status`, and setup()/teardown() are not honored. Sourcing
# ghcr-mirror.sh has no cluster side effects (it only sets defaults and defines
# functions). mikefarah yq prints `---` between matched documents.
#
# Run with: hack/cozytest.sh hack/ghcr-mirror_test.bats
# -----------------------------------------------------------------------------

@test "manifest documents partition into pre-Cilium apply plus the Cilium policy" {
    manifest=hack/e2e-ghcr-mirror.yaml
    total=$(yq '.kind' "$manifest" | grep -vc '^---$')
    excluded=$(yq 'select(.kind != "CiliumClusterwideNetworkPolicy") | .kind' "$manifest" | grep -vc '^---$')
    selected=$(yq 'select(.kind == "CiliumClusterwideNetworkPolicy") | .kind' "$manifest" | grep -vc '^---$')
    [ "$total" -eq 3 ]
    [ "$excluded" -eq 2 ]
    [ "$selected" -eq 1 ]
    [ $((excluded + selected)) -eq "$total" ]
}

@test "pre-Cilium apply keeps Service and Deployment and drops the Cilium policy" {
    manifest=hack/e2e-ghcr-mirror.yaml
    kinds=$(yq 'select(.kind != "CiliumClusterwideNetworkPolicy") | .kind' "$manifest" | grep -v '^---$')
    for want in Service Deployment; do
        printf '%s\n' "$kinds" | grep -qx "$want" || { echo "pre-Cilium apply is missing $want" >&2; exit 1; }
    done
    if printf '%s\n' "$kinds" | grep -qx CiliumClusterwideNetworkPolicy; then
        echo "CiliumClusterwideNetworkPolicy leaked into the pre-Cilium apply" >&2
        exit 1
    fi
}

@test "registry is configured as a pull-through cache for ghcr.io" {
    manifest=hack/e2e-ghcr-mirror.yaml
    remote=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "REGISTRY_PROXY_REMOTEURL") | .value' "$manifest")
    [ "$remote" = "https://ghcr.io" ]
}

@test "egress policy selects the worker VM (virt-launcher) identity that pulls the kubelet image" {
    manifest=hack/e2e-ghcr-mirror.yaml
    label=$(yq 'select(.kind == "CiliumClusterwideNetworkPolicy") | .spec.endpointSelector.matchLabels["k8s:kubevirt.io"]' "$manifest")
    ns=$(yq 'select(.kind == "CiliumClusterwideNetworkPolicy") | .spec.endpointSelector.matchLabels["k8s:io.kubernetes.pod.namespace"]' "$manifest")
    [ "$label" = "virt-launcher" ]
    [ "$ns" = "tenant-test" ]
}

@test "egress rule targets the mirror pod's own identity" {
    manifest=hack/e2e-ghcr-mirror.yaml
    target=$(yq 'select(.kind == "CiliumClusterwideNetworkPolicy") | .spec.egress[0].toEndpoints[0].matchLabels["k8s:app.kubernetes.io/name"]' "$manifest")
    target_ns=$(yq 'select(.kind == "CiliumClusterwideNetworkPolicy") | .spec.egress[0].toEndpoints[0].matchLabels["k8s:io.kubernetes.pod.namespace"]' "$manifest")
    mirror=$(yq 'select(.kind == "Deployment") | .spec.template.metadata.labels["app.kubernetes.io/name"]' "$manifest")
    mirror_ns=$(yq 'select(.kind == "Deployment") | .metadata.namespace' "$manifest")
    [ "$target" = "ghcr-mirror" ]
    [ "$target_ns" = "kube-system" ]
    # The allow's destination must equal the mirror Deployment's own pod label and
    # namespace, otherwise the hole is punched toward nothing.
    [ "$target" = "$mirror" ]
    [ "$target_ns" = "$mirror_ns" ]
}

@test "registryMirrors block is empty when no mirror endpoint is chosen" {
    . hack/e2e-chainsaw/_lib/ghcr-mirror.sh
    out=$(ghcr_registry_mirrors_block "")
    [ -z "$out" ]
}

@test "registryMirrors block renders ghcr.io endpoints indented under spec.talos" {
    . hack/e2e-chainsaw/_lib/ghcr-mirror.sh
    out=$(ghcr_registry_mirrors_block "http://ghcr-mirror.kube-system.svc")
    # 4-space indent so it nests under `  talos:`; ghcr.io host with the endpoint.
    printf '%s\n' "$out" | grep -qx '    registryMirrors:' || { echo "registryMirrors key not at spec.talos indent" >&2; exit 1; }
    printf '%s\n' "$out" | grep -qx '      ghcr.io:' || { echo "ghcr.io host key missing/misindented" >&2; exit 1; }
    printf '%s\n' "$out" | grep -qx '          - http://ghcr-mirror.kube-system.svc' || { echo "endpoint missing/misindented" >&2; exit 1; }
}

@test "registry Deployment runs PSS-restricted (non-root, no priv-esc, dropped caps, RO rootfs, no SA token)" {
    manifest=hack/e2e-ghcr-mirror.yaml
    d='select(.kind == "Deployment")'
    [ "$(yq "$d | .spec.template.spec.automountServiceAccountToken" "$manifest")" = "false" ]
    [ "$(yq "$d | .spec.template.spec.securityContext.runAsNonRoot" "$manifest")" = "true" ]
    [ "$(yq "$d | .spec.template.spec.securityContext.seccompProfile.type" "$manifest")" = "RuntimeDefault" ]
    c='.spec.template.spec.containers[0].securityContext'
    [ "$(yq "$d | $c.allowPrivilegeEscalation" "$manifest")" = "false" ]
    [ "$(yq "$d | $c.readOnlyRootFilesystem" "$manifest")" = "true" ]
    [ "$(yq "$d | $c.capabilities.drop[0]" "$manifest")" = "ALL" ]
}

@test "the manifest and helper agree on the mirror Service DNS name" {
    manifest=hack/e2e-ghcr-mirror.yaml
    helper=hack/e2e-chainsaw/_lib/ghcr-mirror.sh
    svc=$(yq 'select(.kind == "Service") | .metadata.name' "$manifest")
    svc_ns=$(yq 'select(.kind == "Service") | .metadata.namespace' "$manifest")
    # The helper's default endpoint must resolve to the Service this manifest ships,
    # else workers are mirrored at a name that does not exist and fall back silently.
    grep -q "GHCR_MIRROR_SVC_URL:-http://${svc}.${svc_ns}.svc" "$helper" \
        || { echo "helper endpoint drifted from the mirror Service name" >&2; exit 1; }
}
