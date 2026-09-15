#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Unit tests for platform migration 57 --> 58 (detach HTTPCache instances).
#
# HTTPCache stops being shipped. Its PackageSource is pruned on upgrade and takes
# the chart artifacts with it, so the migration orphans every tenant
# http-cache-<name> HelmRelease (suspend, drop the Flux finalizer, verify it is
# gone, delete) and then removes the platform side: the Package, the
# http-cache-rd release, the ApplicationDefinition and the release's Helm
# storage.
#
# Pinned here:
#
#  1. SELECTION. A release is detached when it renders from the http-cache chart
#     or carries the HTTPCache application label, and no other release is touched.
#
#  2. ORDER. Each release goes suspend -> finalizer-drop -> delete. All tenant
#     releases are detached before anything on the platform side is deleted, and
#     the Package is deleted before hr/http-cache-rd: the operator owns that
#     release and re-creates it for as long as its Package exists.
#
#  3. FAIL CLOSED. A finalizer that survives its patch, a failed verify read, a
#     failed fleet scan or a failed platform delete aborts the migration before
#     it stamps the version.
#
# The harness (docker, jq baked onto the migrations base image, the explicit
# `return` in run_migration) is the one hack/migration-55-fluxcd-orphan.bats
# describes; see there for why each piece is load-bearing.
#
# Run with: hack/cozytest.sh hack/migration-57-http-cache-detach.bats
# -----------------------------------------------------------------------------

FAKEBIN="$PWD/hack/testdata/migration-57-http-cache"
MIG_DIR="$PWD/packages/core/platform/images/migrations/migrations"
ALPINE=$(sed -n 's/^FROM \(alpine:[^ ]*\).*$/\1/p' \
  "$PWD/packages/core/platform/images/migrations/Dockerfile" | head -1)
TESTIMG="cozystack-migration57-test:$(printf '%s' "$ALPINE" | sed 's/[^a-zA-Z0-9]/-/g')"
CHART=cozystack-http-cache-application-default-http-cache

run_migration() {
  _run_migration_rc=0
  docker run --rm --network none \
    --user "$(id -u):$(id -g)" \
    -v "$MIG_DIR:/migrations:ro" \
    -v "$FAKEBIN:/fakebin:ro" \
    -v "$WORK:/work" \
    -e PATH=/fakebin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    -e FAKE_CMDLOG=/work/cmdlog \
    -e NAMESPACE="${NAMESPACE-}" \
    -e FAKE_HRS="${FAKE_HRS-}" \
    -e FAKE_LIST_FAIL="${FAKE_LIST_FAIL-}" \
    -e FAKE_FINALIZER_STICKS="${FAKE_FINALIZER_STICKS-}" \
    -e FAKE_VERIFY_READ_FAIL="${FAKE_VERIFY_READ_FAIL-}" \
    -e FAKE_PLATFORM_DELETE_FAIL="${FAKE_PLATFORM_DELETE_FAIL-}" \
    "$TESTIMG" "/migrations/$1" || _run_migration_rc=$?
  return "$_run_migration_rc"
}

prep() {
  docker info >/dev/null 2>&1 || {
    echo "docker is required: these tests run migration 57 inside a jq-enabled" >&2
    echo "build of $ALPINE, the migrations image's base." >&2
    return 1
  }
  docker build -q -t "$TESTIMG" - >/dev/null <<DOCKERFILE
FROM $ALPINE
RUN apk add --no-cache jq
DOCKERFILE
  chmod +x "$FAKEBIN/kubectl"
  WORK=$(mktemp -d)
  export FAKE_CMDLOG="$WORK/cmdlog"
  : > "$FAKE_CMDLOG"
  export NAMESPACE=cozy-system
  export FAKE_HRS=""
  unset FAKE_LIST_FAIL FAKE_FINALIZER_STICKS FAKE_VERIFY_READ_FAIL FAKE_PLATFORM_DELETE_FAIL || true
  return 0
}

cmdlog_line() {
  grep -nE -- "$1" "$FAKE_CMDLOG" | head -1 | cut -d: -f1
}

# Last matching line, for "every X happened before Y" checks.
cmdlog_last() {
  grep -nE -- "$1" "$FAKE_CMDLOG" | tail -1 | cut -d: -f1
}

assert_detached() {
  _s=$(cmdlog_line "^SUSPEND $1 $2$")
  _f=$(cmdlog_line "^FINALIZER-PATCH $1 $2$")
  _d=$(cmdlog_line "^DELETE-HR $1 $2$")
  [ -n "$_s" ] && [ -n "$_f" ] && [ -n "$_d" ] || { echo "missing step for $1/$2: suspend=$_s finalizer=$_f delete=$_d" >&2; return 1; }
  [ "$_s" -lt "$_f" ] && [ "$_f" -lt "$_d" ] || { echo "out-of-order for $1/$2: suspend=$_s finalizer=$_f delete=$_d" >&2; return 1; }
  return 0
}

@test "detaches every HTTPCache release, then removes the platform side Package first, and stamps 58" {
  prep
  # tenant-a/http-cache-web matches on chart and label, tenant-b/http-cache-old
  # only on the label (chartRef never rewritten), tenant-a/redis-cache on neither.
  export FAKE_HRS="tenant-a http-cache-web $CHART HTTPCache
tenant-b http-cache-old some-old-chart HTTPCache
tenant-a redis-cache cozystack-redis-application-default-redis Redis
cozy-system http-cache-rd ${CHART}-rd -"
  rc=0
  run_migration 57 >"$WORK/out" 2>&1 || rc=$?
  cat "$WORK/out"; cat "$FAKE_CMDLOG"
  [ "$rc" -eq 0 ]

  assert_detached tenant-a http-cache-web
  assert_detached tenant-b http-cache-old
  [ "$(grep -cE '^SUSPEND ' "$FAKE_CMDLOG")" -eq 2 ]
  if grep -q 'redis-cache' "$FAKE_CMDLOG"; then echo "unrelated redis-cache was touched" >&2; return 1; fi
  # The rd release is removed by the platform step, never orphaned: orphaning it
  # would keep the ApplicationDefinition alive.
  if grep -qE '^(SUSPEND|FINALIZER-PATCH) cozy-system http-cache-rd$' "$FAKE_CMDLOG"; then echo "http-cache-rd was orphaned" >&2; return 1; fi

  _last_tenant=$(cmdlog_last '^DELETE-HR tenant-')
  _pkg=$(cmdlog_line '^DELETE-PACKAGE cozystack.http-cache-application$')
  _rd=$(cmdlog_line '^DELETE-HR cozy-system http-cache-rd$')
  _ad=$(cmdlog_line '^DELETE-APPDEF http-cache$')
  _sec=$(cmdlog_line '^DELETE-SECRETS cozy-system owner=helm,name=http-cache-rd$')
  _stamp=$(cmdlog_line '^STAMP 58$')
  [ -n "$_pkg" ] && [ -n "$_rd" ] && [ -n "$_ad" ] && [ -n "$_sec" ] && [ -n "$_stamp" ] || { echo "missing platform step: pkg=$_pkg rd=$_rd appdef=$_ad secrets=$_sec stamp=$_stamp" >&2; return 1; }
  [ "$_last_tenant" -lt "$_pkg" ] || { echo "platform cleanup started before all tenants were detached" >&2; return 1; }
  [ "$_pkg" -lt "$_rd" ] || { echo "http-cache-rd deleted before its Package; the operator would re-create it" >&2; return 1; }
  [ "$_sec" -lt "$_stamp" ] && [ "$_ad" -lt "$_stamp" ]
  rm -rf "$WORK"
}

@test "with no HTTPCache instances it still removes the platform side and stamps 58" {
  prep
  export FAKE_HRS="tenant-a redis-cache cozystack-redis-application-default-redis Redis"
  rc=0
  run_migration 57 >"$WORK/out" 2>&1 || rc=$?
  cat "$WORK/out"; cat "$FAKE_CMDLOG"
  [ "$rc" -eq 0 ]
  if grep -qE '^SUSPEND ' "$FAKE_CMDLOG"; then echo "unexpected SUSPEND with no instances" >&2; return 1; fi
  grep -qE '^DELETE-PACKAGE cozystack.http-cache-application$' "$FAKE_CMDLOG"
  grep -qE '^DELETE-APPDEF http-cache$' "$FAKE_CMDLOG"
  grep -qF 'STAMP 58' "$FAKE_CMDLOG"
  rm -rf "$WORK"
}

@test "a finalizer surviving the patch aborts before any delete and before stamping" {
  prep
  export FAKE_HRS="tenant-a http-cache-web $CHART HTTPCache"
  export FAKE_FINALIZER_STICKS=1
  rc=0
  run_migration 57 >"$WORK/out" 2>&1 || rc=$?
  cat "$WORK/out"; cat "$FAKE_CMDLOG"
  [ "$rc" -ne 0 ]
  grep -qF 'refusing to delete' "$WORK/out"
  if grep -qE '^DELETE-' "$FAKE_CMDLOG"; then echo "unexpected delete after stuck finalizer" >&2; return 1; fi
  if grep -qF 'STAMP' "$FAKE_CMDLOG"; then echo "unexpected STAMP after stuck finalizer" >&2; return 1; fi
  rm -rf "$WORK"
}

@test "a failing finalizer verify read aborts before any delete and before stamping" {
  prep
  export FAKE_HRS="tenant-a http-cache-web $CHART HTTPCache"
  export FAKE_VERIFY_READ_FAIL="Error from server (Forbidden): helmreleases.helm.toolkit.fluxcd.io \"http-cache-web\" is forbidden"
  rc=0
  run_migration 57 >"$WORK/out" 2>&1 || rc=$?
  cat "$WORK/out"; cat "$FAKE_CMDLOG"
  [ "$rc" -ne 0 ]
  if grep -qE '^DELETE-' "$FAKE_CMDLOG"; then echo "unexpected delete after failed verify read" >&2; return 1; fi
  if grep -qF 'STAMP' "$FAKE_CMDLOG"; then echo "unexpected STAMP after failed verify read" >&2; return 1; fi
  rm -rf "$WORK"
}

@test "a failing fleet scan aborts before touching anything and before stamping" {
  prep
  export FAKE_HRS="tenant-a http-cache-web $CHART HTTPCache"
  export FAKE_LIST_FAIL="Error from server (Timeout): the server was unable to return a response in the time allotted"
  rc=0
  run_migration 57 >"$WORK/out" 2>&1 || rc=$?
  cat "$WORK/out"; cat "$FAKE_CMDLOG"
  [ "$rc" -ne 0 ]
  if grep -qE '^(SUSPEND|DELETE-)' "$FAKE_CMDLOG"; then echo "unexpected action after failed fleet scan" >&2; return 1; fi
  if grep -qF 'STAMP' "$FAKE_CMDLOG"; then echo "unexpected STAMP after failed fleet scan" >&2; return 1; fi
  rm -rf "$WORK"
}

@test "a failing platform delete aborts before stamping" {
  prep
  export FAKE_HRS=""
  export FAKE_PLATFORM_DELETE_FAIL="Error from server (InternalError): etcdserver: request timed out"
  rc=0
  run_migration 57 >"$WORK/out" 2>&1 || rc=$?
  cat "$WORK/out"; cat "$FAKE_CMDLOG"
  [ "$rc" -ne 0 ]
  if grep -qF 'STAMP' "$FAKE_CMDLOG"; then echo "unexpected STAMP after failed platform delete" >&2; return 1; fi
  rm -rf "$WORK"
}
