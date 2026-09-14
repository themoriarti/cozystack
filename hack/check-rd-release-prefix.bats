#!/usr/bin/env bats
# Unit test: every resourceNames selector in an ApplicationDefinition names the
# object the chart actually creates.
#
# Release names are "<prefix><app name>" (api/v1alpha1/applicationdefinitions_types.go,
# applied in pkg/registry/apps/application/rest.go), but the template context the
# lineage webhook evaluates selectors in carries only {kind, name, namespace} --
# name being the custom resource's name, without the prefix
# (internal/lineagecontrollerwebhook/webhook.go, computeLabels). So a selector has
# to spell the prefix out, and the definitions do: "postgres-{{ .name }}-credentials",
# "bucket-{{ .name }}-credentials", and so on.
#
# Omitting it produces no error anywhere. The selector simply matches nothing, which
# is indistinguishable from a selector that legitimately has nothing to match: the
# webhook labels the object internal.cozystack.io/tenantresource=false and moves on.
# harbor shipped that way and the Secret it names never reached the TenantSecrets
# API; the symptom was worked around by stamping a label on the Secret rather than
# by fixing the name, so the broken selector stayed in the tree unnoticed.
#
# The assertion is "contains <prefix>{{ .name }}" rather than "starts with the
# prefix", because operator-created objects legitimately carry their own leading
# words: mongodb excludes "internal-mongodb-{{ .name }}-users", which is correct and
# must stay green.
#
# Definitions with an empty prefix are skipped: packages/extra/* are generated with
# PREFIX="" by hack/update-crd.sh, so their releases carry no prefix to assert.

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
