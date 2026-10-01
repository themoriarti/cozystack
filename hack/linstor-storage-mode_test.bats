#!/usr/bin/env bats
# Unit coverage for the lane-specific E2E storage contract: LINSTOR pool
# registration, management StorageClasses, and downstream Chainsaw fixtures.
# The library guard keeps this suite cluster-free under hack/cozytest.sh.

HACK_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")" && pwd)"
POST_PREP="$HACK_DIR/e2e-post-install-prep.sh"
# shellcheck source=/dev/null
E2E_POST_INSTALL_PREP_LIB=true . "$POST_PREP"

kubectl() { printf '%s\n' "$*"; }

# The pool waits poll against a wall-clock deadline. Each `date` call moves this
# clock a minute on, so a wait that cannot succeed runs out within a few polls.
# The suite also runs kubectl through `timeout` and `sh -c`, which bypass the
# shell function, so a kubectl that refuses to run goes first on PATH.
fake_linstor_clock() {
  clock_file="_out/tmp/linstor-clock-$$"
  mkdir -p _out/tmp/linstor-bin
  printf '#!/bin/sh\necho "unstubbed kubectl $*" >&2\nexit 97\n' >_out/tmp/linstor-bin/kubectl
  chmod +x _out/tmp/linstor-bin/kubectl
  PATH="$PWD/_out/tmp/linstor-bin:$PATH"
  printf '0\n' >"$clock_file"
  date() {
    _now=$(cat "$clock_file")
    printf '%s\n' "$((_now + 60))" >"$clock_file"
    printf '%s\n' "$_now"
  }
  sleep() { :; }
}

@test "QEMU mode creates data from the satellite block device" {
  unset COZY_LINSTOR_DRBD_ENABLED
  command=$(create_linstor_storage_pool srv2)
  expected='exec -n cozy-linstor deploy/linstor-controller -- linstor physical-storage create-device-pool zfs srv2 /dev/vdc --pool-name data --storage-pool data'

  if [ "$command" != "$expected" ]; then
    echo "unexpected QEMU pool command: $command" >&2
    return 1
  fi
}

@test "container mode registers the node-specific pre-created zpool" {
  COZY_LINSTOR_DRBD_ENABLED=false
  command=$(create_linstor_storage_pool srv2)
  expected='exec -n cozy-linstor deploy/linstor-controller -- linstor storage-pool create zfs srv2 data data-srv2'

  if [ "$command" != "$expected" ]; then
    echo "unexpected container pool command: $command" >&2
    return 1
  fi
}

@test "QEMU mode renders local and replicated StorageClasses" {
  unset COZY_LINSTOR_DRBD_ENABLED
  manifest=$(render_linstor_storageclasses)
  names=$(printf '%s\n' "$manifest" | yq -N '.metadata.name')
  expected_names=$(printf '%s\n' local replicated)
  replicated_layers=$(printf '%s\n' "$manifest" | yq 'select(.metadata.name == "replicated") | .parameters."linstor.csi.linbit.com/layerList"')

  if [ "$names" != "$expected_names" ]; then
    echo "unexpected QEMU StorageClasses: $names" >&2
    return 1
  fi
  if [ "$replicated_layers" != "drbd storage" ]; then
    echo "replicated StorageClass lost its DRBD layer: $replicated_layers" >&2
    return 1
  fi
}

@test "container mode renders only the production local StorageClass" {
  COZY_LINSTOR_DRBD_ENABLED=false
  manifest=$(render_linstor_storageclasses)
  names=$(printf '%s\n' "$manifest" | yq -N '.metadata.name')
  local_layers=$(printf '%s\n' "$manifest" | yq '.parameters."linstor.csi.linbit.com/layerList"')
  remote=$(printf '%s\n' "$manifest" | yq '.parameters."linstor.csi.linbit.com/allowRemoteVolumeAccess"')

  if [ "$names" != "local" ]; then
    echo "container mode emitted unexpected StorageClasses: $names" >&2
    return 1
  fi
  if [ "$local_layers" != "storage" ] || [ "$remote" != "false" ]; then
    echo "container local StorageClass has unexpected parameters: layerList=$local_layers allowRemoteVolumeAccess=$remote" >&2
    return 1
  fi
}

@test "container mode pins CDI local StorageProfile to RWO Block" {
  command=$(patch_local_cdi_storage_profile)
  expected='patch storageprofile local --request-timeout=60s --type merge -p {"spec":{"claimPropertySets":[{"accessModes":["ReadWriteOnce"],"volumeMode":"Block"}]}}'

  if [ "$command" != "$expected" ]; then
    echo "unexpected CDI StorageProfile patch: $command" >&2
    return 1
  fi
}

@test "invalid DRBD mode is rejected before cluster access" {
  COZY_LINSTOR_DRBD_ENABLED=unsupported
  if validate_linstor_storage_mode; then
    echo "invalid DRBD mode unexpectedly passed validation" >&2
    return 1
  fi
}

@test "tenant Kubernetes storage defaults to replicated and accepts local only explicitly" {
  # Sourcing inside the test keeps run-kubernetes.sh's live-cluster
  # cozy_cleanup helper out of cozytest.sh's file-level cleanup discovery.
  # shellcheck source=/dev/null
  . "$HACK_DIR/e2e-chainsaw/_lib/run-kubernetes.sh"
  unset COZY_E2E_STORAGE_CLASS
  default_class=$(cozy_e2e_storage_class)
  COZY_E2E_STORAGE_CLASS=local
  container_class=$(cozy_e2e_storage_class)

  if [ "$default_class" != replicated ] || [ "$container_class" != local ]; then
    echo "unexpected tenant storage classes: default=$default_class container=$container_class" >&2
    return 1
  fi

  COZY_E2E_STORAGE_CLASS=unsupported
  if cozy_e2e_storage_class; then
    echo "invalid tenant storage class unexpectedly passed validation" >&2
    return 1
  fi
}

@test "replicated cleanup holds LINSTOR capacity to the pre-suite baseline, not to an absolute floor" {
  # shellcheck source=/dev/null
  . "$HACK_DIR/e2e-chainsaw/_lib/run-kubernetes.sh"
  COZY_E2E_STORAGE_CLASS=replicated
  COZY_LINSTOR_POOL_BASELINE_FILE="_out/tmp/linstor-baseline-$$"
  mkdir -p _out/tmp
  # srv2 sits at 83 GiB both before and after the suite, below the 90 GiB that
  # used to be demanded of every node, because earlier suites hold the space.
  pools=$(printf 'srv1:92452208\nsrv2:87127923\nsrv3:133999575')
  printf '%s\n' "$pools" >"$COZY_LINSTOR_POOL_BASELINE_FILE"
  # The baseline probe reads node:kib rows; the absolute-floor probe reads the
  # smallest pool as kib:node. Each gets its own shape, so a cleanup that went
  # back to the floor fails on srv2's 83 GiB rather than on a parse error.
  kubectl() {
    case "$*" in
      *'free_capacity):'*) printf '87127923:srv2\n' ;;
      *linstor*) printf '%s\n' "$pools" ;;
    esac
    return 0
  }
  cozy_wait_tenant_drained() { return 0; }
  fake_linstor_clock

  rc=0
  cozy_cleanup test-latest-version || rc=$?
  rm -f "$COZY_LINSTOR_POOL_BASELINE_FILE" "$clock_file"

  if [ "$rc" -ne 0 ]; then
    echo "replicated cleanup failed although every pool is back at its pre-suite free capacity" >&2
    return 1
  fi
}

@test "replicated Kubernetes suite records a LINSTOR baseline before creating the tenant" {
  # shellcheck source=/dev/null
  . "$HACK_DIR/e2e-chainsaw/_lib/run-kubernetes.sh"
  COZY_E2E_STORAGE_CLASS=replicated
  COZY_LINSTOR_POOL_BASELINE_FILE="_out/tmp/linstor-baseline-$$"
  yq() { printf 'v1.33.12\n'; }
  # The first apply creates the tenant. Exiting the command substitution there
  # also keeps the run away from the `sh -c` loops further on, which would
  # call the real kubectl.
  kubectl() {
    case "$*" in apply*) printf 'UNEXPECTED_TENANT_APPLY\n'; exit 99 ;; esac
    return 0
  }
  cozy_wait_tenant_drained() { return 0; }
  cozy_wait_linstor_pool_free() { return 0; }
  cozy_capture_linstor_pool_baseline() { printf 'BASELINE_CAPTURED\n'; return 42; }
  fake_linstor_clock

  rc=0
  output=$(run_kubernetes_test '.' test-latest-version 59991) || rc=$?
  rm -f "$clock_file"

  if ! printf '%s\n' "$output" | grep -Fq BASELINE_CAPTURED; then
    echo "replicated suite went on without recording a pre-suite LINSTOR baseline" >&2
    return 1
  fi
  if [ "$rc" -eq 0 ] || printf '%s\n' "$output" | grep -Fq UNEXPECTED_TENANT_APPLY; then
    echo "replicated suite continued after the baseline capture failed" >&2
    return 1
  fi
}

@test "replicated suite starting below the LINSTOR pool floor stops early and blames the environment" {
  # shellcheck source=/dev/null
  . "$HACK_DIR/e2e-chainsaw/_lib/run-kubernetes.sh"
  COZY_E2E_STORAGE_CLASS=replicated
  COZY_LINSTOR_POOL_BASELINE_FILE="_out/tmp/linstor-baseline-$$"
  yq() { printf 'v1.33.12\n'; }
  kubectl() {
    case "$*" in
      *machine-readable*) printf '87127923:srv2\n' ;;
      *'sp l'*) printf '| data | srv2 | ZFS | data | 83.09 GiB | 199 GiB |\n' ;;
      apply*) printf 'UNEXPECTED_TENANT_APPLY\n'; exit 99 ;;
    esac
    return 0
  }
  cozy_wait_tenant_drained() { return 0; }
  cozy_capture_linstor_pool_baseline() { return 0; }
  fake_linstor_clock

  rc=0
  output=$(run_kubernetes_test '.' test-latest-version 59991 2>&1) || rc=$?
  rm -f "$clock_file"

  if [ "$rc" -eq 0 ] || printf '%s\n' "$output" | grep -Fq UNEXPECTED_TENANT_APPLY; then
    echo "suite went on to create its tenant with srv2 below the pool floor" >&2
    return 1
  fi
  if ! printf '%s\n' "$output" | grep -Fq 'earlier suites'; then
    echo "the low-pool failure does not name the environment as its cause" >&2
    return 1
  fi
  if ! printf '%s\n' "$output" | grep -Fq '83.09 GiB'; then
    echo "the low-pool failure does not print the per-node pool table" >&2
    return 1
  fi
}

@test "local Kubernetes suite does not demand the replicated lane's pool floor" {
  # shellcheck source=/dev/null
  . "$HACK_DIR/e2e-chainsaw/_lib/run-kubernetes.sh"
  COZY_E2E_STORAGE_CLASS=local
  COZY_LINSTOR_POOL_BASELINE_FILE="_out/tmp/linstor-baseline-$$"
  yq() { printf 'v1.33.12\n'; }
  kubectl() {
    case "$*" in apply*) printf 'TENANT_APPLY_REACHED\n'; exit 0 ;; esac
    return 0
  }
  cozy_wait_tenant_drained() { return 0; }
  cozy_wait_linstor_pool_free() { printf 'UNEXPECTED_FLOOR\n'; return 99; }
  cozy_capture_linstor_pool_baseline() { return 0; }
  fake_linstor_clock

  output=$(run_kubernetes_test '.' test-latest-version 59991 2>&1) || true
  rm -f "$clock_file"

  if printf '%s\n' "$output" | grep -Fq UNEXPECTED_FLOOR; then
    echo "local suite waited for the 90 GiB floor that its platform volumes keep one pool below" >&2
    return 1
  fi
  if ! printf '%s\n' "$output" | grep -Fq TENANT_APPLY_REACHED; then
    echo "local suite stopped before creating its tenant: $output" >&2
    return 1
  fi
}

@test "a suite that fails before recording its baseline cannot reuse the previous suite's" {
  # shellcheck source=/dev/null
  . "$HACK_DIR/e2e-chainsaw/_lib/run-kubernetes.sh"
  COZY_LINSTOR_POOL_BASELINE_FILE="_out/tmp/linstor-baseline-$$"
  mkdir -p _out/tmp
  pools=$(printf 'srv1:92452208\nsrv2:87127923\nsrv3:133999575')
  printf '%s\n' "$pools" >"$COZY_LINSTOR_POOL_BASELINE_FILE"
  yq() { printf 'v1.33.12\n'; }
  kubectl() {
    case "$*" in *linstor*) printf '%s\n' "$pools" ;; esac
    return 0
  }
  cozy_wait_tenant_drained() { return 1; }
  run_kubernetes_test '.' test-latest-version 59991 >/dev/null 2>&1 || true
  fake_linstor_clock

  rc=0
  cozy_wait_linstor_pool_baseline 0 >/dev/null 2>&1 || rc=$?
  rm -f "$COZY_LINSTOR_POOL_BASELINE_FILE" "$clock_file"

  if [ "$rc" -eq 0 ]; then
    echo "cleanup verified reclamation against the previous suite's baseline" >&2
    return 1
  fi
}

@test "pool baseline comparison is per-node and tolerates only metadata drift" {
  # shellcheck source=/dev/null
  . "$HACK_DIR/e2e-chainsaw/_lib/run-kubernetes.sh"
  baseline=$(printf 'srv1:67108864\nsrv2:20787200\nsrv3:60817408')
  within_tolerance=$(printf 'srv1:67108864\nsrv2:20262912\nsrv3:60817408')
  leaked_worker=$(printf 'srv1:67108864\nsrv2:20787200\nsrv3:39845888')
  missing_node=$(printf 'srv1:67108864\nsrv3:60817408')

  cozy_linstor_pools_at_baseline "$baseline" "$within_tolerance" 524288
  if cozy_linstor_pools_at_baseline "$baseline" "$leaked_worker" 524288; then
    echo "a 20 GiB worker leak passed the local-pool baseline" >&2
    return 1
  fi
  if cozy_linstor_pools_at_baseline "$baseline" "$missing_node" 524288; then
    echo "a missing LINSTOR node passed the local-pool baseline" >&2
    return 1
  fi
}

@test "pool baseline capture persists all three numeric satellite rows" {
  # shellcheck source=/dev/null
  . "$HACK_DIR/e2e-chainsaw/_lib/run-kubernetes.sh"
  COZY_LINSTOR_POOL_BASELINE_FILE="_out/tmp/linstor-baseline-$$"
  kubectl() { printf 'srv3:60817408\nsrv1:67108864\nsrv2:20787200\n'; }

  output=$(cozy_capture_linstor_pool_baseline)
  captured=$(cat "$COZY_LINSTOR_POOL_BASELINE_FILE")
  rm -f "$COZY_LINSTOR_POOL_BASELINE_FILE"

  [ "$captured" = "$(printf 'srv3:60817408\nsrv1:67108864\nsrv2:20787200')" ]
  printf '%s\n' "$output" | grep -Fq 'LINSTOR pool baseline recorded'
}

@test "Kubernetes cleanup fails when LINSTOR capacity is not reclaimed" {
  # shellcheck source=/dev/null
  . "$HACK_DIR/e2e-chainsaw/_lib/run-kubernetes.sh"
  kubectl() { return 0; }
  cozy_wait_tenant_drained() { return 0; }
  cozy_wait_linstor_pool_baseline() { return 42; }

  if cozy_cleanup test-latest-version; then
    echo "cleanup hid the failed LINSTOR reclamation barrier" >&2
    return 1
  fi
}

@test "cleanup of a suite that never recorded a baseline does not report a leak" {
  # shellcheck source=/dev/null
  . "$HACK_DIR/e2e-chainsaw/_lib/run-kubernetes.sh"
  COZY_LINSTOR_POOL_BASELINE_FILE="_out/tmp/linstor-baseline-absent-$$"
  rm -f "$COZY_LINSTOR_POOL_BASELINE_FILE"
  kubectl() { return 0; }
  cozy_wait_tenant_drained() { return 0; }
  fake_linstor_clock

  rc=0
  output=$(cozy_cleanup test-latest-version 2>&1) || rc=$?
  rm -f "$clock_file"

  if [ "$rc" -eq 0 ]; then
    echo "cleanup passed with LINSTOR reclamation unchecked" >&2
    return 1
  fi
  if printf '%s\n' "$output" | grep -Fq 'did not return to the pre-suite level'; then
    echo "cleanup blamed the suite for a leak although it stopped before recording a baseline: $output" >&2
    return 1
  fi
}

@test "local Kubernetes suite cannot start without a LINSTOR baseline" {
  # shellcheck source=/dev/null
  . "$HACK_DIR/e2e-chainsaw/_lib/run-kubernetes.sh"
  COZY_E2E_STORAGE_CLASS=local
  COZY_LINSTOR_POOL_BASELINE_FILE="_out/tmp/linstor-baseline-$$"
  yq() { printf 'v1.33.12\n'; }
  kubectl() { return 0; }
  cozy_wait_tenant_drained() { return 0; }
  cozy_capture_linstor_pool_baseline() { return 42; }
  helm() { printf 'UNEXPECTED_HELM_CALL\n'; return 99; }
  fake_linstor_clock

  rc=0
  output=$(run_kubernetes_test '.' test-latest-version 59991) || rc=$?
  rm -f "$clock_file"

  if [ "$rc" -eq 0 ]; then
    echo "suite accepted a failed local LINSTOR baseline capture" >&2
    return 1
  fi
  if printf '%s\n' "$output" | grep -Fq UNEXPECTED_HELM_CALL; then
    echo "suite continued into Helm after the baseline capture failed" >&2
    return 1
  fi
}

@test "Kubernetes cleanup operations outlive their bounded reclamation stages" {
  for suite in latest previous; do
    timeout=$(yq "select(.metadata.name == \"kubernetes-${suite}\") | .spec.steps[0].finally[0].script.timeout" "hack/e2e-chainsaw/kubernetes-${suite}/chainsaw-test.yaml")
    if [ "$timeout" != 22m ]; then
      echo "kubernetes-${suite} cleanup timeout is $timeout, expected 22m" >&2
      return 1
    fi
  done
}

@test "both merge-gating lanes forward local storage through install and Chainsaw" {
  # Checked in both workflows rather than one: pull-requests.yaml gates same-repo
  # PRs and e2e-fork.yaml gates fork PRs, they carry the override separately, and
  # a lane that installs on `local` while templating Chainsaw with `replicated`
  # fails deep inside a suite rather than at the mismatch.
  install_command=$(make -n -C packages/core/testing SANDBOX_NAME=test COZY_E2E_STORAGE_CLASS=local install-cozystack)
  make_command=$(make -n -C packages/core/testing SANDBOX_NAME=test COZY_E2E_STORAGE_CLASS=local CHAINSAW_SUITES=vminstance test-chainsaw)

  for wf in .github/workflows/pull-requests.yaml .github/workflows/e2e-fork.yaml; do
    install_value=$(yq '.jobs.e2e.steps[] | select(.name == "Install Cozystack into sandbox") | .env.COZY_E2E_STORAGE_CLASS' "$wf")
    run_value=$(yq '.jobs.e2e.steps[] | select(.name == "Run E2E tests") | .env.COZY_E2E_STORAGE_CLASS' "$wf")
    if [ "$install_value" != local ] || [ "$run_value" != local ]; then
      echo "unexpected storage modes in $wf: install=$install_value chainsaw=$run_value" >&2
      return 1
    fi
  done
  if ! printf '%s\n' "$install_command" | grep -Fq -- '-e COZY_E2E_STORAGE_CLASS="local"'; then
    echo "testing Makefile does not forward COZY_E2E_STORAGE_CLASS into installation" >&2
    return 1
  fi
  if ! printf '%s\n' "$make_command" | grep -Fq -- '-e COZY_E2E_STORAGE_CLASS="local"'; then
    echo "testing Makefile does not forward COZY_E2E_STORAGE_CLASS into the sandbox" >&2
    return 1
  fi
  if ! printf '%s\n' "$make_command" | grep -Fq -- '--set-string storageClass="${COZY_E2E_STORAGE_CLASS:-replicated}" vminstance'; then
    echo "testing Makefile does not pass the lane storage class to Chainsaw values" >&2
    return 1
  fi
}

@test "container install supplies VictoriaLogs local storage before monitoring exists" {
  install_suite=hack/e2e-install-cozystack.bats

  if ! grep -Fq 'storage_class="${COZY_E2E_STORAGE_CLASS:-replicated}"' "$install_suite"; then
    echo "install suite does not retain the replicated QEMU default" >&2
    return 1
  fi
  if ! grep -Fq 'kubectl patch secret cozystack-values -n tenant-root --type merge --patch-file "$root_values_patch_file"' "$install_suite"; then
    echo "install suite does not put the monitoring override in root values" >&2
    return 1
  fi
  if grep -Fq 'kubectl patch hr/monitoring' "$install_suite"; then
    echo "install suite still races monitoring reconciliation with a HelmRelease patch" >&2
    return 1
  fi
  if ! grep -Fq '.logsStorages = [{"name":"generic","retentionPeriod":"1","storage":"10Gi","storageClassName":strenv(COZY_E2E_STORAGE_CLASS)}]' "$install_suite"; then
    echo "monitoring override does not preserve the required VictoriaLogs values" >&2
    return 1
  fi

  secret_patch_line=$(grep -nF 'kubectl patch secret cozystack-values' "$install_suite" | cut -d: -f1)
  tenant_patch_line=$(grep -nF 'kubectl patch tenants/root' "$install_suite" | cut -d: -f1)
  if [ -z "$secret_patch_line" ] || [ -z "$tenant_patch_line" ] || [ "$secret_patch_line" -ge "$tenant_patch_line" ]; then
    echo "root values must be patched before monitoring is enabled: secret=$secret_patch_line tenant=$tenant_patch_line" >&2
    return 1
  fi

  rendered=$(mktemp)
  helm template monitoring packages/extra/monitoring --namespace tenant-root \
    --set-string 'logsStorages[0].name=generic' \
    --set-string 'logsStorages[0].retentionPeriod=1' \
    --set-string 'logsStorages[0].storage=10Gi' \
    --set-string 'logsStorages[0].storageClassName=local' > "$rendered"
  rendered_class=$(yq 'select(.kind == "HelmRelease" and .metadata.name == "monitoring-system") | .spec.values.logsStorages[0].storageClassName' "$rendered")
  rm -f "$rendered"
  if [ "$rendered_class" != local ]; then
    echo "monitoring chart did not carry the root values override into its child release: $rendered_class" >&2
    return 1
  fi
}

@test "DRBD-dependent fixtures and Kubernetes checks consume the lane storage mode" {
  for manifest in hack/e2e-chainsaw/vminstance/vmdisk.yaml hack/e2e-chainsaw/vminstance/vmdisk-vmi.yaml; do
    storage_class=$(yq '.spec.storageClass' "$manifest")
    if [ "$storage_class" != '($values.storageClass)' ]; then
      echo "$manifest does not consume the Chainsaw storageClass value: $storage_class" >&2
      return 1
    fi
  done

  kubernetes_script=hack/e2e-chainsaw/_lib/run-kubernetes.sh
  rendered_uses=$(grep -Fc 'storageClass: "${storage_class}"' "$kubernetes_script")
  if [ "$rendered_uses" -ne 2 ]; then
    echo "expected both tenant Kubernetes resources to consume storage_class, found $rendered_uses" >&2
    return 1
  fi
  if ! grep -Fq 'if [ "$storage_class" = local ]; then' "$kubernetes_script"; then
    echo "local-only Kubernetes suites do not omit DRBD/RWX assertions" >&2
    return 1
  fi
  if ! grep -Fq 'if [ "$storage_class" = replicated ]; then' "$kubernetes_script"; then
    echo "fallback regression does not limit replicated StorageClass restoration to QEMU" >&2
    return 1
  fi
}
