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
