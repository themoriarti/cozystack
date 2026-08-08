#!/bin/sh
# Read a list of changed files (one per line) and emit space-separated suite
# names whose Chainsaw suites under hack/e2e-chainsaw/ should run.
#
# Usage: hack/select-e2e.sh <changed-files> [<sources-dir>]
# Defaults: sources-dir = packages/core/platform/sources
#
# Output:
#   - empty         no E2E impact, decided by one of the rules that select
#                   nothing: step 1 for docs/, dashboards/ and *.md, step 2 for
#                   an examples/backups/<app>/ with no suite, and
#                   inert_config_pattern for repo meta and agent config
#   - <suite names> selected per the PackageSource dependency graph
#   - full list     any path that affects all tests, OR an unrecognised
#                   packages/* path, OR a per-app source whose graph has
#                   no *-application descendants, OR a path matching NEITHER
#                   the full-suite nor the inert list (conservative fallbacks)
#
# Every changed path must land in exactly one of those three classes by an
# explicit rule. An unclassified path escalates to the full suite rather than
# selecting nothing: both e2e lanes read an empty selection as "skip Chainsaw"
# and then post the required "E2E Tests" status green, so a silent default is a
# green gate with no suite run (#3392). When that escalation fires for a path
# that genuinely cannot affect e2e, add it to inert_config_pattern — do not
# widen the fall-through.
#
# "Empty" is not a synonym for inert_config_pattern. Several rules select
# nothing: step 1 for docs/, dashboards/ and *.md, step 2 for an
# examples/backups/<app>/ whose app has no suite, and the pattern itself. The
# property the lanes depend on is weaker than "matched the inert list" and it is
# the one to preserve: an empty selection is a decision some rule reached, never
# a path nothing looked at.
#
# One caveat worth knowing before trusting that: inert_config_pattern makes
# .github/ inert as a whole directory, and the e2e workflows are exempted by
# NAME in full_suite_pattern, which is checked first. So a workflow added under
# .github/workflows/ that runs the suite is silently inert until someone adds it
# to that list — the fall-through never sees it. The enumeration is the guard,
# which is why it carries the `rg -l test-chainsaw` reminder; treat that comment
# as load-bearing rather than decorative.
set -eu

CHANGED="${1:?missing changed-files arg}"
SOURCES_DIR="${2:-packages/core/platform/sources}"

# Anything matching this pattern triggers the full Chainsaw suite. Per-suite
# edits (hack/e2e-chainsaw/<name>/...) are matched BEFORE this so editing one
# suite doesn't escalate to the full suite; the shared _lib helpers and the
# .chainsaw.yaml config affect every suite and DO escalate (handled inline).
#
# Three groups, all "cannot be scoped to one app":
#   - shipped code and its build inputs: packages/library, packages/core, the Go
#     trees (api, cmd, internal, pkg), the codegen under tools/, go.mod/go.sum,
#     the root Makefile, hack/*.mk (the tag/push/output flags of every image),
#     hack/buildkitd.toml (the builder every image is built with), and hack/lib/
#     (sourced by the hack/*.sh scripts that already escalate);
#   - the e2e harness itself: hack/*.sh, hack/*.bats and hack/e2e-*.yaml;
#   - the workflows that RUN the suite — enumerated rather than matched by
#     prefix, so an unrelated workflow does not burn a full run. Keep this list
#     in step with `rg -l test-chainsaw .github/workflows/`.
#
#     What that costs, stated rather than left to be rediscovered: only
#     pull-requests.yaml is executed from the PR's own head. e2e-fork runs on
#     workflow_run, which always takes the default-branch copy; e2e-tag runs on
#     workflow_call from a tag push; nightly runs on a schedule. So for those
#     three the suite cannot exercise the edit under review, and escalating buys
#     generic regression coverage rather than coverage of the change. Measured
#     over the last six months of main: 26 commits touch one of the three with
#     no other escalating path, and each now pays a full Chainsaw run it would
#     previously have skipped. They stay on the list so the rule remains one
#     idea ("workflows that run the suite") rather than two, and because the
#     alternative leaves them inert, which reads as an oversight rather than a
#     decision. Reopen the trade if the full suite's flake rate makes the
#     generic coverage cost more than it returns.
full_suite_pattern='^(packages/library/|packages/core/|api/|cmd/|internal/|pkg/|tools/|hack/lib/|hack/[^/]+\.sh$|hack/[^/]+\.bats$|hack/[^/]+\.mk$|hack/buildkitd\.toml$|hack/e2e-[^/]+\.ya?ml$|go\.(mod|sum)$|Makefile$|\.github/workflows/(pull-requests|e2e-fork|e2e-tag|nightly)\.yaml$)'

# Paths with no bearing on what e2e exercises. Checked AFTER full_suite_pattern,
# so a specific escalation wins over a broad directory here (.github/ is inert,
# .github/workflows/pull-requests.yaml is not). This list is the whole reason
# the fall-through at the bottom of the loop can escalate safely: the cost of
# forgetting an inert path is a wasted full run, the cost of forgetting a live
# one used to be a green gate with nothing tested.
#   - examples/       demo manifests; examples/backups/<app>/ is handled above
#                     as a real test harness before this check is reached
#   - .github/        templates, CODEOWNERS, labels, renovate, linter config —
#                     minus the e2e workflows escalated above
#   - .claude/ .gemini/  agent config, never shipped
#   - img/            README assets
#   - hack/testdata/  fixtures for the bats unit tests, not for e2e
#   - boilerplate.go.txt / dcgm-default-counters.csv  codegen header; a CSV read
#                     only by check-gpu-recording-rules.bats
inert_config_pattern='^(examples/|\.github/|\.claude/|\.gemini/|img/|hack/testdata/|hack/boilerplate\.go\.txt$|hack/dcgm-default-counters\.csv$|LICENSE$|\.gitignore$|\.pre-commit-config\.yaml$|\.coderabbit\.yaml$)'

# All known Chainsaw suites: every dir under hack/e2e-chainsaw/ holding a
# chainsaw-test.yaml (this excludes _lib/ and the top-level config files).
all_apps=$(find hack/e2e-chainsaw -mindepth 2 -maxdepth 2 -name chainsaw-test.yaml 2>/dev/null \
  | sed -e 's,^hack/e2e-chainsaw/,,' -e 's,/chainsaw-test\.yaml$,,' | sort)

# PackageSource name -> Chainsaw suite name(s). Most *-application sources map
# by stripping the suffix; explicit overrides for the few that don't.
src_to_suites() {
  case "$1" in
    postgres-application) echo postgres ;;
    vm-instance-application) echo vminstance ;;
    kubernetes-application) echo "kubernetes-latest kubernetes-previous kubernetes-oidc-system kubernetes-oidc-customconfig" ;;
    external-dns) echo external-dns ;;
    *-application) echo "${1%-application}" ;;
    *) echo "$1" ;;
  esac
}

# yq: path -> PackageSource name
build_owners_index() {
  yq -rN '.metadata.name as $n | .spec.variants[]?.components[]?.path | select(. != null and . != "") | . + "\t" + $n' "$SOURCES_DIR"/*.yaml
}

# yq: PackageSource name -> sources that depend on it (reverse of dependsOn)
#
# Exclude cozystack.cozystack-engine as a propagation hub. Every *-application
# source declares `dependsOn: cozystack.cozystack-engine` purely as an INSTALL
# ORDERING edge — the app's *-rd HelmRelease must wait for the engine to
# register the ApplicationDefinition CRD before it can reconcile. That is a
# universal lifecycle dependency, NOT a behavioral one: a change to an engine
# dependency (postgres-operator, keycloak, cert-manager, ...) does not alter any
# app's runtime behavior, so it must not fan test selection out to every app.
# Without this filter, postgres-operator -> keycloak -> cozystack-engine -> EVERY
# app, defeating test-impact analysis. Dropping the engine reverse edges keeps
# the engine reachable but stops it propagating selection downstream. A change to
# the engine itself still triggers the full suite via the no-app-descendants
# safety-net at the bottom of this script.
build_reverse_deps() {
  yq -rN '.metadata.name as $n | .spec.variants[]?.dependsOn[]? | select(. != null and . != "" and . != "cozystack.cozystack-engine") | . + "\t" + $n' "$SOURCES_DIR"/*.yaml
}

OWNERS=$(build_owners_index | sort -u)
REVERSE=$(build_reverse_deps | sort -u)

trigger_full=0
trigger_any=0
selected_sources=""
selected_apps=""

# `|| [ -n "$file" ]` is what makes the classification below total. POSIX read
# assigns the last line and then returns non-zero when the input does not end in
# a newline, so a plain `while read` silently drops it. That is the one way a
# path can reach this loop and be classified by nothing at all: the fall-through
# at the end, which exists so an unrecognised path escalates instead of
# selecting nothing, sits inside the body the drop skips. Callers building the
# list themselves rather than piping `git diff` are the ones that hit it, and
# the guard belongs here rather than in each of them.
while IFS= read -r file || [ -n "$file" ]; do
  [ -z "$file" ] && continue

  # 1. Skip: docs, dashboards, *.md. Checked before everything else because
  #    these can never matter wherever they live — a README inside
  #    packages/core/ must not escalate the way its templates do.
  if echo "$file" | grep -qE '^(docs/|dashboards/)' || echo "$file" | grep -qE '\.md$'; then
    continue
  fi

  # 2. Chainsaw edits. A per-suite file selects only that suite; the shared
  #    _lib helpers and the .chainsaw.yaml config affect every suite, so they
  #    escalate to the full run.
  case "$file" in
    hack/e2e-chainsaw/_lib/*|hack/e2e-chainsaw/.chainsaw.yaml)
      trigger_full=1
      continue ;;
    hack/e2e-chainsaw/*/*)
      app=$(echo "$file" | sed -nE 's,^hack/e2e-chainsaw/([^/]+)/.*,\1,p')
      selected_apps="$selected_apps $app"
      trigger_any=1
      continue ;;
    examples/backups/*/*)
      # The etcd and postgres backup round-trip tests execute the example
      # scripts under examples/backups/<app>/ as their harness, so an edit
      # there must run that app's suite. A dir with no matching suite is a
      # docs-only demo and stays ignored (adding it to selected_apps would
      # empty the final intersection and trip the full-suite safety net).
      app=$(echo "$file" | sed -nE 's,^examples/backups/([^/]+)/.*,\1,p')
      if echo "$all_apps" | grep -Fxq "$app"; then
        selected_apps="$selected_apps $app"
        trigger_any=1
      fi
      continue ;;
  esac

  # 3. Full-suite trigger
  if echo "$file" | grep -qE "$full_suite_pattern"; then
    trigger_full=1
    continue
  fi

  # 4. Explicitly inert: repo meta, agent config, non-e2e workflows, fixtures.
  if echo "$file" | grep -qE "$inert_config_pattern"; then
    continue
  fi

  # 5. Component change: lookup in PackageSource graph
  rel=$(echo "$file" | sed -nE 's,^packages/(apps|system|extra)/([^/]+)/.*,\1/\2,p')
  if [ -n "$rel" ]; then
    src=$(echo "$OWNERS" | awk -v p="$rel" -F'\t' '$1==p {print $2}')
    if [ -n "$src" ]; then
      selected_sources="$selected_sources $src"
      trigger_any=1
    else
      # Inside packages/ but no graph entry — be conservative.
      trigger_full=1
    fi
    continue
  fi

  # 6. Unclassified. Escalate instead of ignoring: an empty selection makes both
  #    e2e lanes skip Chainsaw and post "E2E Tests" green, so a path nobody has
  #    classified must fail safe, not fail open (#3392). Add genuinely inert
  #    paths to inert_config_pattern rather than relaxing this.
  echo "select-e2e: unclassified path '$file' — escalating to the full suite (classify it in hack/select-e2e.sh, see #3392)" >&2
  trigger_full=1
done < "$CHANGED"

if [ "$trigger_full" = 1 ]; then
  echo "$all_apps" | paste -sd ' ' -
  exit 0
fi

if [ "$trigger_any" = 0 ]; then
  exit 0  # nothing to run
fi

# Transitive closure: walk reverse-deps from each selected source.
all_sources="$selected_sources"
while :; do
  new=""
  for s in $all_sources; do
    deps=$(echo "$REVERSE" | awk -v src="$s" -F'\t' '$1==src {print $2}')
    for d in $deps; do
      case " $all_sources " in *" $d "*) ;; *) new="$new $d";; esac
    done
  done
  [ -z "$new" ] && break
  all_sources="$all_sources $new"
done

# Filter to *-application sources, then map to Chainsaw suite names.
final=""
for s in $all_sources; do
  app=${s#cozystack.}
  case "$app" in
    *-application) final="$final $(src_to_suites "$app")" ;;
    external-dns) final="$final external-dns" ;;
  esac
done

# Add directly-selected suites from per-suite edits.
final="$final $selected_apps"

# Deduplicate; intersect with available Chainsaw suites.
final_apps=$(echo "$final" | tr ' ' '\n' | sort -u | grep -v '^$' | while read -r app; do
  if echo "$all_apps" | grep -Fxq "$app"; then
    echo "$app"
  fi
done | paste -sd ' ' -)

# Safety net: a system source with no *-application descendants would otherwise
# silently skip E2E. Fall back to full suite so a path inside the graph is
# never silently dropped.
if [ -z "$final_apps" ]; then
  echo "$all_apps" | paste -sd ' ' -
  exit 0
fi

echo "$final_apps"
