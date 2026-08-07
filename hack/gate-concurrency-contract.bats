#!/usr/bin/env bats

# Contract for the concurrency keys that decide which run owns the required
# "E2E Tests" commit status (see docs/agents/e2e-testing.md §10).
#
# The gate is a status, not a job, so a run that dies without posting leaves the
# head SHA at "Expected" and blocks the merge forever. That makes the pairing
# below load-bearing: `e2e-fork.yaml`'s `resolve` declines to post for a
# triggering run that concluded `cancelled`/`skipped`, and the workflow's
# concurrency key must put exactly those runs in a group of their own so a run
# that posts nothing cannot cancel the run that does. The two lists live in
# different languages in different halves of the file and can drift apart in a
# way no reviewer diff makes obvious — a third discarded conclusion added to the
# JS guard alone silently restores the wedge. These tests pin executable lines
# only: a commented-out key must never satisfy the contract.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
FORK="$REPO_ROOT/.github/workflows/e2e-fork.yaml"
PULL_REQUESTS="$REPO_ROOT/.github/workflows/pull-requests.yaml"

# Drop YAML `#` and JavaScript `//` comment lines. grep exits 1 when nothing is
# selected (legitimate) and 2 on a real error, so only the latter propagates.
code_lines() {
  local rc=0
  grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*//' || rc=$?
  [ "$rc" -le 1 ]
}

# Conclusions the concurrency key routes into a per-run group.
group_key_conclusions() {
  code_lines < "$FORK" \
    | grep '^  group: e2e-fork-' \
    | grep -o "workflow_run\.conclusion == '[a-z_]*'" \
    | sed "s/.*'\\(.*\\)'/\\1/" \
    | sort -u
}

# Conclusions `resolve` treats as "not a verdict" and posts nothing for.
resolve_silent_conclusions() {
  code_lines < "$FORK" \
    | grep '^ *if (CONCLUSION ===' \
    | grep -o "CONCLUSION === '[a-z_]*'" \
    | sed "s/.*'\\(.*\\)'/\\1/" \
    | sort -u
}

@test "fork gate: a run that posts no status cannot cancel the run that does" {
  group="$(group_key_conclusions)"
  silent="$(resolve_silent_conclusions)"

  # Guard the instrument: an empty side would make the comparison vacuous.
  [ -n "$silent" ]
  [ -n "$group" ]

  [ "$group" = "$silent" ]
}

@test "fork gate: the per-run discriminator is the triggering run id" {
  line="$(code_lines < "$FORK" | grep '^  group: e2e-fork-')"
  [ -n "$line" ]

  count="$(printf '%s\n' "$line" | grep -c 'github\.event\.workflow_run\.id' || true)"
  [ "${count:-0}" -eq 1 ]
}

@test "fork gate: real runs still supersede each other on fork repo + branch" {
  line="$(code_lines < "$FORK" | grep '^  group: e2e-fork-')"
  [ -n "$line" ]

  count="$(printf '%s\n' "$line" | grep -c 'workflow_run\.head_repository\.full_name' || true)"
  [ "${count:-0}" -eq 1 ]

  count="$(printf '%s\n' "$line" | grep -c 'workflow_run\.head_branch' || true)"
  [ "${count:-0}" -eq 1 ]

  count="$(code_lines < "$FORK" | grep -c '^  cancel-in-progress: true$' || true)"
  [ "${count:-0}" -eq 1 ]
}

@test "same-repo gate: labeled events keep their own concurrency group" {
  line="$(code_lines < "$PULL_REQUESTS" | grep '^  group: pr-')"
  [ -n "$line" ]

  count="$(printf '%s\n' "$line" | grep -c "github\.event\.action == 'labeled'" || true)"
  [ "${count:-0}" -eq 1 ]

  count="$(code_lines < "$PULL_REQUESTS" | grep -c '^  cancel-in-progress: true$' || true)"
  [ "${count:-0}" -eq 1 ]
}
