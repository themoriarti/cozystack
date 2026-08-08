# shellcheck shell=bash
# Shared helper: point tenant Kubernetes e2e worker nodes at the in-sandbox
# ghcr.io pull-through registry (hack/e2e-ghcr-mirror.yaml) when it is up, via the
# chart's `talos.registryMirrors` knob, otherwise emit nothing so workers fall back
# to pulling ghcr.io directly (the mirror can only help, never make CI worse).
#
# Why: tenant worker Talos nodes pull `ghcr.io/siderolabs/kubelet` directly; that
# egress is flaky/rate-limited from the CI runner and the pull times out with a TLS
# handshake timeout, so the kubelet service never starts and no tenant node joins.
# Diagnosed in cozystack/cozystack#3548 (in-guest Talos dmesg), tracked by #3513.
# Same flaky-public-egress class the talos-image-cache (#3231) fixed for the OS image.
#
# NOTE: this half cannot be validated without a CI run. It is intentionally simpler
# than talos-image-cache.sh (rollout-status gate + egress-allow, no tenant-scoped
# reachability probe yet); a byte-level reachability probe from a virt-launcher-labelled
# Pod is a hardening follow-up once CI confirms the base path.

GHCR_MIRROR_SVC_URL="${GHCR_MIRROR_SVC_URL:-http://ghcr-mirror.kube-system.svc}"
_GHCR_MIRROR_DECISION_FILE="${_GHCR_MIRROR_DECISION_FILE:-/tmp/e2e-ghcr-mirror-endpoint}"
GHCR_MIRROR_MANIFEST="${GHCR_MIRROR_MANIFEST:-hack/e2e-ghcr-mirror.yaml}"

# ghcr_registry_mirrors_block: pure string builder. Given a mirror endpoint URL
# ($1, may be empty), print the `registryMirrors:` sub-block for a tenant Kubernetes
# CR `spec.talos` (4-space indented, i.e. nested under `  talos:`), or nothing when
# the endpoint is empty. Kept separate so it can be unit-tested: an indentation or
# quoting slip here would emit an invalid CR and every kubernetes-* test would fail.
ghcr_registry_mirrors_block() {
  local endpoint="$1"
  [ -n "$endpoint" ] || return 0
  printf '    registryMirrors:\n      ghcr.io:\n        endpoints:\n          - %s\n' "$endpoint"
}

# _apply_ghcr_mirror_egress_policy: install the CiliumClusterwideNetworkPolicy that
# lets tenant worker VM (virt-launcher) Pods egress to the mirror. It ships in the
# manifest but is applied here, after Cilium's CRDs exist. Idempotent, best-effort.
_apply_ghcr_mirror_egress_policy() {
  command -v yq >/dev/null 2>&1 || return 1
  yq 'select(.kind == "CiliumClusterwideNetworkPolicy")' "$GHCR_MIRROR_MANIFEST" 2>/dev/null \
    | kubectl apply -f - >/dev/null 2>&1
}

# resolve_ghcr_mirror_endpoint: print the mirror endpoint URL to use, or an empty
# string to signal "pull ghcr.io directly". Resolved once and cached in a /tmp file
# that persists across bats files (same sandbox container), so only the first tenant
# test pays the readiness wait.
resolve_ghcr_mirror_endpoint() {
  if [ -f "$_GHCR_MIRROR_DECISION_FILE" ]; then
    cat "$_GHCR_MIRROR_DECISION_FILE"
    return 0
  fi
  local endpoint="" cache=1 out rc
  # One `get deploy` serves both the existence check and the not-deployed-vs-error
  # split: a genuine NotFound is a stable decision worth caching, but any other
  # failure (transient apiserver blip) must NOT be cached, or one blip would
  # disable the mirror for every later test in the shared sandbox.
  #
  # Capture inside `if` (not a bare `out=$(...); rc=$?`): the chainsaw suites run
  # this script under `sh -c` with `set -eu`, and dash inherits errexit into a
  # command substitution, so a non-zero kubectl in a bare assignment would kill
  # the script before either fallback branch runs. bash does not inherit it,
  # which is why a bare assignment survives locally but not in CI.
  if out=$(kubectl -n kube-system get deploy ghcr-mirror 2>&1); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *NotFound*|*"not found"*)
        echo "ghcr-mirror not deployed -- tenant workers pull ghcr.io directly" >&2 ;;
      *)
        echo "WARNING: could not query ghcr-mirror Deployment (transient); not caching, will retry" >&2
        cache=0 ;;
    esac
  elif kubectl -n kube-system rollout status deploy/ghcr-mirror --timeout=5m >/dev/null 2>&1; then
    # Only commit the endpoint once the tenant egress allow is actually in place.
    # The mirror is a kube-system ClusterIP that the tenant default-deny egress
    # drops without this allow; pointing workers at it when the policy did not
    # apply just adds dial-timeout latency before Talos falls back. Leaving the
    # endpoint empty keeps the "can only help, never make CI worse" invariant.
    if _apply_ghcr_mirror_egress_policy; then
      endpoint="$GHCR_MIRROR_SVC_URL"
      echo "ghcr-mirror ready and egress allow applied -- tenant workers mirror ghcr.io via ${endpoint}" >&2
    else
      echo "WARNING: ghcr-mirror ready but its egress allow failed to apply -- tenant workers pull ghcr.io directly" >&2
    fi
  else
    echo "WARNING: ghcr-mirror not Available in time -- tenant workers pull ghcr.io directly" >&2
  fi
  # Cache atomically (temp + mv) so a concurrent reader in the shared sandbox never
  # sees a half-written decision file.
  if [ "$cache" -eq 1 ]; then
    printf '%s' "$endpoint" > "${_GHCR_MIRROR_DECISION_FILE}.tmp" \
      && mv "${_GHCR_MIRROR_DECISION_FILE}.tmp" "$_GHCR_MIRROR_DECISION_FILE"
  fi
  printf '%s' "$endpoint"
}
