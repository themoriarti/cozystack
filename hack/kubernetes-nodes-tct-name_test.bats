#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# The worker TalosConfigTemplate is named by a hash of its rendered spec, and
# that one name appears in three places that live in two templates of the
# kubernetes-nodes chart:
#   - MachineDeployment.spec.template.spec.bootstrap.configRef.name
#     (templates/nodegroup.yaml), which is what CAPI rolls the pool onto;
#   - TCT_NAME in the talos-reconcile Job (templates/talos-reconcile-job.yaml),
#     which is the object the Job actually applies;
#   - the Job Role's named get/patch/update and delete rules on that template.
# If any of them disagreed, the MachineDeployment would wait forever on a
# template nobody creates, or the Job would be forbidden from touching the one
# it does create. helm-unittest asserts one document at a time, so the
# cross-document equality is checked here, on a kubevirt and a proxmox pool,
# and on a pool with a forced talosConfigRevision.
#
# Needs `helm` + `yq`; cozytest.sh runs from the repo root.
# Run with: hack/cozytest.sh hack/kubernetes-nodes-tct-name_test.bats
# -----------------------------------------------------------------------------

@test "kubernetes-nodes MachineDeployment, reconcile Job and its Role agree on the TalosConfigTemplate name" {
    work=$(mktemp -d)
    cat > "$work/kubevirt.yaml" <<'VALS'
cluster: myk8s
_cluster:
  cluster-domain: cozy.local
version: "v1.35"
minReplicas: 0
maxReplicas: 3
instanceType: ""
diskSize: 20Gi
storageClass: replicated
roles: [ingress-nginx]
resources: {cpu: "2", memory: 4Gi}
VALS
    cat > "$work/proxmox.yaml" <<'VALS'
cluster: myk8s
_cluster:
  cluster-domain: cozy.local
version: "v1.35"
minReplicas: 0
maxReplicas: 3
instanceType: ""
roles: [ingress-nginx]
resources: {cpu: "4", memory: 8Gi}
substrate: proxmox
proxmox:
  templateTags: [capmox-template, cozystack, talos, talos-v1.13.6]
  full: true
  network: {bridge: vmbr0}
  storage: ""
  dnsServers: ["8.8.8.8"]
VALS
    # A forced revision moves the name in all three places at once.
    { cat "$work/kubevirt.yaml"; echo 'talosConfigRevision: "2026-10-08"'; } > "$work/revision.yaml"
    for substrate in kubevirt proxmox revision; do
        helm template kubernetes-nodes-myk8s-md0 packages/apps/kubernetes-nodes -n tenant-test -f "$work/$substrate.yaml" \
            > "$work/$substrate.out" 2>"$work/$substrate.err" \
            || { echo "$substrate: helm template failed" >&2; cat "$work/$substrate.err" >&2; rm -rf "$work"; exit 1; }
        md=$(yq 'select(.kind == "MachineDeployment") | .spec.template.spec.bootstrap.configRef.name' "$work/$substrate.out")
        job=$(yq 'select(.kind == "Job" and (.metadata.name | test("talos-reconcile"))) | .spec.template.spec.containers[0].env[] | select(.name == "TCT_NAME") | .value' "$work/$substrate.out")
        rw=$(yq 'select(.kind == "Role" and .metadata.name == "kubernetes-nodes-myk8s-md0-talos-reconcile") | .rules[] | select(.resources[0] == "talosconfigtemplates" and .verbs[0] == "get") | .resourceNames[0]' "$work/$substrate.out")
        del=$(yq 'select(.kind == "Role" and .metadata.name == "kubernetes-nodes-myk8s-md0-talos-reconcile") | .rules[] | select(.resources[0] == "talosconfigtemplates" and .verbs[0] == "delete") | .resourceNames[0]' "$work/$substrate.out")
        printf '%s' "$md" | grep -Eq '^kubernetes-myk8s-md0-[0-9a-f]{6}$' \
            || { echo "$substrate: MachineDeployment configRef '$md' is not a content-hashed name" >&2; rm -rf "$work"; exit 1; }
        [ "$job" = "$md" ] || { echo "$substrate: Job TCT_NAME '$job' != MachineDeployment configRef '$md'" >&2; rm -rf "$work"; exit 1; }
        [ "$rw" = "$md" ] || { echo "$substrate: Role get/patch/update names '$rw', not '$md'" >&2; rm -rf "$work"; exit 1; }
        [ "$del" = "$md" ] || { echo "$substrate: Role delete names '$del' first, not '$md'" >&2; rm -rf "$work"; exit 1; }
    done
    kv=$(yq 'select(.kind == "MachineDeployment") | .spec.template.spec.bootstrap.configRef.name' "$work/kubevirt.out")
    px=$(yq 'select(.kind == "MachineDeployment") | .spec.template.spec.bootstrap.configRef.name' "$work/proxmox.out")
    [ "$kv" != "$px" ] || { echo "kubevirt and proxmox pools render different machineconfigs but share the name '$kv'" >&2; rm -rf "$work"; exit 1; }
    rv=$(yq 'select(.kind == "MachineDeployment") | .spec.template.spec.bootstrap.configRef.name' "$work/revision.out")
    [ "$rv" != "$kv" ] || { echo "talosConfigRevision did not move the name off '$kv'" >&2; rm -rf "$work"; exit 1; }
    rm -rf "$work"
}
