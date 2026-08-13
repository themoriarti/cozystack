#!/usr/bin/env bats
# Structural contract for abandoned stable-candidate artifact retention.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
RETENTION="$REPO_ROOT/.github/workflows/retention.yaml"

code_lines() {
  rc=0
  grep -v '^[[:space:]]*#' || rc=$?
  [ "$rc" -le 1 ]
}

step_block() {
  awk -v want="      - name: $1" '
    $0 == want { inside = 1; next }
    /^      - name: / { inside = 0 }
    inside' "$2"
}

@test "retention deletes only old packages versions carrying temporary tags alone" {
  block="$(step_block 'Prune' "$RETENTION")"
  [ -n "$block" ]

  printf '%s\n' "$block" | code_lines | grep -qF "pkg='cozystack/cozystack-packages'"
  printf '%s\n' "$block" | code_lines | grep -qF 'select((.metadata.container.tags | length) > 0)'
  printf '%s\n' "$block" | code_lines | grep -qF 'select(.metadata.container.tags | all(test("^promotion-v'
  printf '%s\n' "$block" | code_lines | grep -qF -- '-run-[0-9]+-[0-9]+$'
  printf '%s\n' "$block" | code_lines | grep -qF 'select(.updated_at < $cutoff)'
  printf '%s\n' "$block" | code_lines | grep -qF 'index($digest)) == null'
}

@test "retention protects candidates pinned by open bot release PRs" {
  block="$(step_block 'Prune' "$RETENTION")"
  [ -n "$block" ]

  printf '%s\n' "$block" | code_lines | grep -qF 'pulls?state=open&per_page=100'
  printf '%s\n' "$block" | code_lines | grep -qF '.user.login == "cozystack-ci[bot]"'
  printf '%s\n' "$block" | code_lines | grep -qF '.head.repo.full_name == $repo'
  printf '%s\n' "$block" | code_lines | grep -qF 'any(.labels[]?; .name == "release")'
  printf '%s\n' "$block" | code_lines | grep -qF '/^[\047"]|[\047"][[:space:]]*$/'
  printf '%s\n' "$block" | code_lines | grep -qF "grep -Eq '^digest=sha256:[0-9a-f]{64}$'"
  printf '%s\n' "$block" | code_lines | grep -qF 'refusing retention'
}

@test "retention also protects candidates pinned by a base-branch tip" {
  # The open PR is not the whole danger window. A candidate stops being
  # eligible only once finalize's retag puts a stable tag on its manifest, and
  # finalize runs after the merge that closes the PR — so between those two
  # points the branch tip is the only thing still naming the digest.
  block="$(step_block 'Prune' "$RETENTION")"
  [ -n "$block" ]

  printf '%s\n' "$block" | code_lines | grep -qF 'branches?per_page=100'
  printf '%s\n' "$block" | code_lines \
    | grep -qF 'select(. == "main" or test("^release-[0-9]+\\.[0-9]+$"))'
  printf '%s\n' "$block" | code_lines | grep -qF "grep -oE 'digest=sha256:[0-9a-f]{64}'"
}

@test "an unresolved pin stops the promotion sweep and nothing else" {
  # Fail-closed for deletion is right; taking the unrelated nightly sweep down
  # with it is not. A WIP commit adding a trailing comment to a pin on a
  # release branch would otherwise silently stop GHCR nightly pruning.
  block="$(step_block 'Prune' "$RETENTION")"
  [ -n "$block" ]

  printf '%s\n' "$block" | code_lines | grep -qF 'promotion_retention_blocked=1'
  printf '%s\n' "$block" | code_lines | grep -qF 'skipping the promotion sweep'

  # The guard has to sit between the nightly sweep and the promotion sweep:
  # ahead of the nightly one it is the coupling it exists to remove, behind the
  # promotion one it does not guard it.
  nightly="$(printf '%s\n' "$block" | code_lines \
    | grep -nF 'nightlies, keep ${KEEP}, drop' | awk -F: 'NR == 1 { print $1 }')"
  guard="$(printf '%s\n' "$block" | code_lines \
    | grep -nF 'skipping the promotion sweep' | awk -F: 'NR == 1 { print $1 }')"
  sweep="$(printf '%s\n' "$block" | code_lines \
    | grep -nF "pkg='cozystack/cozystack-packages'" | awk -F: 'NR == 1 { print $1 }')"
  [ -n "$nightly" ] && [ -n "$guard" ] && [ -n "$sweep" ]
  [ "$nightly" -lt "$guard" ]
  [ "$guard" -lt "$sweep" ]
}
