#!/usr/bin/env bats
# Behavioural tests for the pre-publication packages artifact verification.
# Run with: hack/cozytest.sh hack/verify-promoted-packages_test.bats

_test_workspace() {
  if [ -n "${BATS_TEST_TMPDIR:-}" ]; then
    printf '%s\n' "$BATS_TEST_TMPDIR"
  else
    printf '%s\n' "${tmp:?cozytest workspace is missing}"
  fi
}

_make_verify_fixture() {
  t="$1"
  mkdir -p "$t/bin" "$t/release/core/installer" "$t/release/system/dashboard"
  mkdir -p "$t/artifact/core/installer" "$t/artifact/system/dashboard"
  mkdir -p "$t/rc-artifact/core/installer" "$t/rc-artifact/system/dashboard"
  cat > "$t/bin/flux" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = "pull" ]
[ "$2" = "artifact" ]
shift 2
ref="$1"
printf '%s\n' "$@" >> "$MOCK_FLUX_LOG"
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output" ]; then
    out="$2"
    shift 2
  else
    shift
  fi
done
[ -n "$out" ]
case "$ref" in
  *@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
    src="$MOCK_ARTIFACT"
    ;;
  *@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
    src="$MOCK_RC_ARTIFACT"
    ;;
  *)
    echo "unexpected artifact ref: $ref" >&2
    exit 1
    ;;
esac
cp -R "$src"/. "$out"/
EOF
  chmod +x "$t/bin/flux"
  cat > "$t/release/core/installer/values.yaml" <<'EOF'
cozystackOperator:
  platformSourceUrl: oci://ghcr.io/cozystack/cozystack/cozystack-packages
  platformSourceRef: digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
  cat > "$t/artifact/core/installer/values.yaml" <<'EOF'
cozystackOperator:
  platformSourceUrl: oci://ghcr.io/cozystack/cozystack/cozystack-packages
  platformSourceRef: digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
  image='ghcr.io/cozystack/cozystack/cozystack-ui:v9.9.9@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
  printf 'console:\n  image: %s\n' "$image" > "$t/release/system/dashboard/values.yaml"
  printf 'console:\n  image: %s\n' "$image" > "$t/artifact/system/dashboard/values.yaml"
  cp "$t/artifact/core/installer/values.yaml" "$t/rc-artifact/core/installer/values.yaml"
  printf 'console:\n  image: %s\n' \
    'ghcr.io/cozystack/cozystack/cozystack-ui:v9.9.9-rc.3@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
    > "$t/rc-artifact/system/dashboard/values.yaml"
  # Flux's established packages archive omits symlinks. The verifier must
  # compare against that archive view rather than demanding this node back.
  ln -s values.yaml "$t/release/system/dashboard/values-link.yaml"
}

@test "accepts an identical candidate with only the self-reference changed" {
  tmp="$(_test_workspace)/fixture"
  _make_verify_fixture "$tmp"

  rc=0
  MOCK_ARTIFACT="$tmp/artifact" MOCK_RC_ARTIFACT="$tmp/rc-artifact" MOCK_FLUX_LOG="$tmp/flux.log" \
    VERIFY_PACKAGES_WORKDIR="$tmp/work" \
    PATH="$tmp/bin:$PATH" \
    hack/verify-promoted-packages.sh 9.9.9 "$tmp/release" \
    > "$tmp/out" 2> "$tmp/err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "verification exited $rc" >&2
    cat "$tmp/err" >&2
    return "$rc"
  fi

  grep -qx 'oci://ghcr.io/cozystack/cozystack/cozystack-packages@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$tmp/flux.log"
  grep -q "stable tags, identical package tree, and the rc artifact's container digests" "$tmp/out"
}

@test "rejects an rc image reference inside the candidate" {
  tmp="$(_test_workspace)/fixture"
  _make_verify_fixture "$tmp"
  sed 's/:v9.9.9@/:v9.9.9-rc.3@/' "$tmp/artifact/system/dashboard/values.yaml" \
    > "$tmp/rc-values.yaml"
  mv "$tmp/rc-values.yaml" "$tmp/artifact/system/dashboard/values.yaml"

  rc=0
  MOCK_ARTIFACT="$tmp/artifact" MOCK_RC_ARTIFACT="$tmp/rc-artifact" MOCK_FLUX_LOG="$tmp/flux.log" \
    VERIFY_PACKAGES_WORKDIR="$tmp/work" \
    PATH="$tmp/bin:$PATH" \
    hack/verify-promoted-packages.sh 9.9.9 "$tmp/release" \
    > "$tmp/out" 2> "$tmp/err" || rc=$?

  [ "$rc" -ne 0 ]
  grep -q 'still carries rc image references' "$tmp/err"
}

@test "rejects package content changed after the candidate was published" {
  tmp="$(_test_workspace)/fixture"
  _make_verify_fixture "$tmp"
  printf 'changed: true\n' > "$tmp/release/system/dashboard/extra.yaml"

  rc=0
  MOCK_ARTIFACT="$tmp/artifact" MOCK_RC_ARTIFACT="$tmp/rc-artifact" MOCK_FLUX_LOG="$tmp/flux.log" \
    VERIFY_PACKAGES_WORKDIR="$tmp/work" \
    PATH="$tmp/bin:$PATH" \
    hack/verify-promoted-packages.sh 9.9.9 "$tmp/release" \
    > "$tmp/out" 2> "$tmp/err" || rc=$?

  [ "$rc" -ne 0 ]
  grep -q 'contain different files' "$tmp/err"
}

@test "rejects a candidate outside the trusted release repository" {
  tmp="$(_test_workspace)/fixture"
  _make_verify_fixture "$tmp"
  sed 's#oci://ghcr.io/cozystack/cozystack/cozystack-packages#oci://example.invalid/cozystack-packages#' \
    "$tmp/release/core/installer/values.yaml" > "$tmp/untrusted-values.yaml"
  mv "$tmp/untrusted-values.yaml" "$tmp/release/core/installer/values.yaml"

  rc=0
  MOCK_ARTIFACT="$tmp/artifact" MOCK_RC_ARTIFACT="$tmp/rc-artifact" MOCK_FLUX_LOG="$tmp/flux.log" \
    VERIFY_PACKAGES_WORKDIR="$tmp/work" \
    PATH="$tmp/bin:$PATH" \
    hack/verify-promoted-packages.sh 9.9.9 "$tmp/release" \
    > "$tmp/out" 2> "$tmp/err" || rc=$?

  [ "$rc" -ne 0 ]
  grep -q 'must equal trusted repository' "$tmp/err"
  [ ! -s "$tmp/flux.log" ]
}

@test "rejects an embedded rc baseline outside the trusted release repository" {
  tmp="$(_test_workspace)/fixture"
  _make_verify_fixture "$tmp"
  sed 's#oci://ghcr.io/cozystack/cozystack/cozystack-packages#oci://example.invalid/cozystack-packages#' \
    "$tmp/artifact/core/installer/values.yaml" > "$tmp/untrusted-values.yaml"
  mv "$tmp/untrusted-values.yaml" "$tmp/artifact/core/installer/values.yaml"

  rc=0
  MOCK_ARTIFACT="$tmp/artifact" MOCK_RC_ARTIFACT="$tmp/rc-artifact" MOCK_FLUX_LOG="$tmp/flux.log" \
    VERIFY_PACKAGES_WORKDIR="$tmp/work" \
    PATH="$tmp/bin:$PATH" \
    hack/verify-promoted-packages.sh 9.9.9 "$tmp/release" \
    > "$tmp/out" 2> "$tmp/err" || rc=$?

  [ "$rc" -ne 0 ]
  grep -q "candidate's original platformSourceUrl.*must equal trusted repository" "$tmp/err"
}

@test "rejects installer drift beyond the self-reference" {
  tmp="$(_test_workspace)/fixture"
  _make_verify_fixture "$tmp"
  printf '  platformSourceSecret: changed-after-push\n' \
    >> "$tmp/release/core/installer/values.yaml"

  rc=0
  MOCK_ARTIFACT="$tmp/artifact" MOCK_RC_ARTIFACT="$tmp/rc-artifact" MOCK_FLUX_LOG="$tmp/flux.log" \
    VERIFY_PACKAGES_WORKDIR="$tmp/work" \
    PATH="$tmp/bin:$PATH" \
    hack/verify-promoted-packages.sh 9.9.9 "$tmp/release" \
    > "$tmp/out" 2> "$tmp/err" || rc=$?

  [ "$rc" -ne 0 ]
  grep -q 'installer values differ beyond their self-reference' "$tmp/err"
}

@test "rejects a changed container digest even when candidate and merge tree match" {
  tmp="$(_test_workspace)/fixture"
  _make_verify_fixture "$tmp"
  sed 's/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/' \
    "$tmp/artifact/system/dashboard/values.yaml" > "$tmp/changed-values.yaml"
  mv "$tmp/changed-values.yaml" "$tmp/artifact/system/dashboard/values.yaml"
  cp "$tmp/artifact/system/dashboard/values.yaml" "$tmp/release/system/dashboard/values.yaml"

  rc=0
  MOCK_ARTIFACT="$tmp/artifact" MOCK_RC_ARTIFACT="$tmp/rc-artifact" MOCK_FLUX_LOG="$tmp/flux.log" \
    VERIFY_PACKAGES_WORKDIR="$tmp/work" \
    PATH="$tmp/bin:$PATH" \
    hack/verify-promoted-packages.sh 9.9.9 "$tmp/release" \
    > "$tmp/out" 2> "$tmp/err" || rc=$?

  [ "$rc" -ne 0 ]
  grep -q 'promotion changed the container repository/digest set' "$tmp/err"
}
