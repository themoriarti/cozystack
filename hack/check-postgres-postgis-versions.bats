#!/usr/bin/env bats
# Unit test: the postgis flavor of packages/apps/postgres must run the same
# PostgreSQL minor as the default flavor. files/versions.yaml and
# files/postgis-versions.yaml are two maps kept by hand or by
# hack/update-versions.sh; if they drift, `flavor: postgis` silently deploys
# an older or newer minor than the one the chart advertises. The postgis
# image must also be the standard-trixie variant: the chart archives through
# the barman-cloud plugin, and the system variant is deprecated upstream.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
PG_FILES="$REPO_ROOT/packages/apps/postgres/files"

@test "postgis flavor pins the same PostgreSQL minor as the default flavor" {
  checked=0
  while IFS=': ' read -r major tag; do
    major="${major//\"/}"
    tag="${tag//\"/}"
    [ -n "$major" ] || continue
    minor="$(grep "^\"${major}\":" "$PG_FILES/versions.yaml" | sed -E 's/.*"v([0-9.]+)"$/\1/')"
    [ -n "$minor" ] || { echo "$major is in postgis-versions.yaml but not in versions.yaml" >&2; exit 1; }
    case "$tag" in
      "${minor}"-*-standard-trixie) ;;
      *) echo "$major: postgis tag $tag does not match PostgreSQL $minor standard-trixie" >&2; exit 1 ;;
    esac
    checked=$((checked + 1))
  done < "$PG_FILES/postgis-versions.yaml"
  [ "$checked" -gt 0 ] || { echo "no entry read from postgis-versions.yaml" >&2; exit 1; }
}
