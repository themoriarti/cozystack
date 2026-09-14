#!/usr/bin/env bats
# "contains <prefix>{{ .name }}" rather than a prefix match: operator-created
# objects carry their own leading words, such as redis's "rfs-redis-{{ .name }}"
# and mongodb's excluded "internal-mongodb-{{ .name }}-users".
#
# An empty spec.release.prefix is skipped: hack/update-crd.sh generates the
# definitions for packages/extra charts with PREFIX="".

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"

@test "every resourceNames selector carries its release prefix" {
  command -v yq >/dev/null || { echo "yq (mikefarah v4+) is required" >&2; exit 1; }

  violations=""
  total=0
  for f in "$REPO_ROOT"/packages/system/*-rd/cozyrds/*.yaml; do
    [ -f "$f" ] || continue
    prefix="$(yq -r '.spec.release.prefix // ""' "$f")"
    [ -n "$prefix" ] || continue

    # One "<section>.<include|exclude>: <name>" row per selector entry.
    names="$(yq -r '
      .spec | (.secrets, .services, .ingresses) | select(. != null)
      | (.include, .exclude) | select(. != null) | .[]
      | .resourceNames | select(. != null) | .[]
      | (path | .[1] + "." + .[2]) + ": " + .
    ' "$f")"
    [ -n "$names" ] || continue
    total=$(( total + $(printf '%s\n' "$names" | grep -c .) ))

    bad="$(printf '%s\n' "$names" | grep -vF "${prefix}{{ .name }}" || true)"
    [ -z "$bad" ] || violations="$violations$(printf '%s\n' "$bad" | sed "s|^|${f#"$REPO_ROOT"/}: |")
"
  done

  # A glob that matched nothing, or a yq that stopped returning names, would
  # otherwise pass silently.
  [ "$total" -ge 1 ] || { echo "inspected zero selectors; this test is broken" >&2; exit 1; }

  if [ -n "$violations" ]; then
    echo "resourceNames selectors that can never match the object their chart creates:" >&2
    printf '%s' "$violations" >&2
    echo "Fix: spell the release prefix out, e.g. \"harbor-{{ .name }}-credentials\"." >&2
    exit 1
  fi
}
