#!/usr/bin/env bats
# Structural contract for publishing and verifying stable-candidate packages.
# The registry workflow cannot run in a PR lane, so ordering around the first
# write-once stable tag is pinned here. Behaviour lives in the two *_test suites.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
PROMOTE="$REPO_ROOT/.github/workflows/promote-rc.yaml"
FINALIZE="$REPO_ROOT/.github/workflows/pull-requests-release.yaml"
PULL_REQUESTS="$REPO_ROOT/.github/workflows/pull-requests.yaml"

code_lines() {
  rc=0
  grep -v '^[[:space:]]*#' || rc=$?
  [ "$rc" -le 1 ]
}

job_block() {
  awk -v job="  $1:" '
    $0 == job { inside = 1; next }
    /^  [a-z0-9_-]+:$/ { inside = 0 }
    inside' "$2"
}

step_block() {
  awk -v want="      - name: $1" '
    $0 == want { inside = 1; next }
    /^      - name: / { inside = 0 }
    inside' "$2"
}

step_line() {
  code_lines < "$2" | grep -nF "      - name: $1" | awk -F: 'NR == 1 { print $1 }'
}

@test "candidate publish and verification helpers exist and are executable" {
  [ -x "$REPO_ROOT/hack/promote-packages-artifact.sh" ]
  [ -x "$REPO_ROOT/hack/verify-promoted-packages.sh" ]
}

@test "promote commits the rewritten tree then publishes and commits its pin" {
  block="$(step_block 'Prepare stable branch' "$PROMOTE")"
  [ -n "$block" ]

  rewrite="$(printf '%s\n' "$block" | code_lines | grep -nF '.release-tooling/hack/promote-rewrite-tags.sh' | awk -F: 'NR == 1 { print $1 }')"
  publish="$(printf '%s\n' "$block" | code_lines | grep -nF '.release-tooling/hack/promote-packages-artifact.sh' | awk -F: 'NR == 1 { print $1 }')"
  content_commit="$(printf '%s\n' "$block" | code_lines | grep -nF 'git commit -s -m "Prepare release' | awk -F: 'NR == 1 { print $1 }')"
  pin_commit="$(printf '%s\n' "$block" | code_lines | grep -nF 'git commit -s -m "Pin promoted packages artifact' | awk -F: 'NR == 1 { print $1 }')"
  [ -n "$rewrite" ] && [ -n "$content_commit" ] && [ -n "$publish" ] && [ -n "$pin_commit" ]
  [ "$rewrite" -lt "$content_commit" ]
  [ "$content_commit" -lt "$publish" ]
  [ "$publish" -lt "$pin_commit" ]

  # The helper comes from the dispatch ref's sparse tooling checkout, so the
  # first release after this fix does not depend on the older rc tree carrying it.
  printf '%s\n' "$block" | code_lines | grep -qF '.release-tooling/hack/promote-packages-artifact.sh'
  printf '%s\n' "$block" | code_lines | grep -qF 'SOURCE_SHA="$(git rev-parse HEAD)"'
  printf '%s\n' "$block" | code_lines | grep -qF 'PROMOTION_ID: ${{ github.run_id }}-${{ github.run_attempt }}'
}

@test "promote authenticates Flux with the same Docker config used by publish" {
  job="$(job_block promote "$PROMOTE")"
  login="$(step_block 'Login to registry (GHCR)' "$PROMOTE")"
  prepare="$(step_block 'Prepare stable branch' "$PROMOTE")"

  printf '%s\n' "$job" | code_lines | grep -qF '      packages: write'
  printf '%s\n' "$job" | code_lines | grep -qF 'FLUX_VERSION: "2.8.6"'
  printf '%s\n' "$job" | code_lines | grep -qF 'flux version --client'
  printf '%s\n' "$login" | code_lines | grep -qF 'DOCKER_CONFIG: ${{ runner.temp }}/.docker'
  printf '%s\n' "$prepare" | code_lines | grep -qF 'DOCKER_CONFIG: ${{ runner.temp }}/.docker'
}

@test "finalize verifies the pinned candidate before the first stable tag" {
  verify="$(step_line 'Verify stable packages candidate' "$FINALIZE")"
  create="$(step_line 'Create tag on merge commit (write-once)' "$FINALIZE")"
  [ -n "$verify" ] && [ -n "$create" ]
  [ "$verify" -lt "$create" ]

  block="$(step_block 'Verify stable packages candidate' "$FINALIZE")"
  printf '%s\n' "$block" | code_lines | grep -qF '.release-tooling/hack/verify-promoted-packages.sh "${TAG#v}"'

  setup="$(step_block 'Set up promotion toolchain (flux, skopeo, yq, helm)' "$FINALIZE")"
  printf '%s\n' "$setup" | code_lines | grep -qF 'FLUX_VERSION: "2.8.6"'
  printf '%s\n' "$setup" | code_lines | grep -qF 'flux version --client'
}

@test "promote rejects an old target base before publishing a candidate" {
  validate="$(step_block 'Validate rc is promotable' "$PROMOTE")"
  prepare_line="$(step_line 'Prepare stable branch' "$PROMOTE")"
  validate_line="$(step_line 'Validate rc is promotable' "$PROMOTE")"
  [ -n "$validate" ] && [ -n "$validate_line" ] && [ -n "$prepare_line" ]
  [ "$validate_line" -lt "$prepare_line" ]

  printf '%s\n' "$validate" | code_lines | grep -qF "['.github/workflows/pull-requests.yaml', 'verify-release-candidate:']"
  printf '%s\n' "$validate" | code_lines | grep -qF "['.github/workflows/pull-requests-release.yaml', 'Verify stable packages candidate']"
  printf '%s\n' "$validate" | code_lines | grep -qF "['hack/verify-promoted-packages.sh', 'EXPECTED_PACKAGES_REPOSITORY']"
  printf '%s\n' "$validate" | code_lines | grep -qF "core.setOutput('base_branch', baseBranch)"

  open_pr="$(step_block 'Open promote (release) PR' "$PROMOTE")"
  printf '%s\n' "$open_pr" | code_lines | grep -qF 'BASE_BRANCH: ${{ needs.promote.outputs.base_branch }}'
  printf '%s\n' "$open_pr" | code_lines | grep -qF 'BASE="$BASE_BRANCH"'
}

@test "pull request gate verifies the prospective merge with trusted base tooling" {
  job="$(job_block verify-release-candidate "$PULL_REQUESTS")"
  [ -n "$job" ]

  printf '%s\n' "$job" | code_lines | grep -qF "github.event.pull_request.user.login == 'cozystack-ci[bot]'"
  printf '%s\n' "$job" | code_lines | grep -qF 'ref: ${{ github.event.pull_request.base.sha }}'
  printf '%s\n' "$job" | code_lines | grep -qF '.release-tooling/hack/verify-promoted-packages.sh "$STABLE_VERSION"'
  printf '%s\n' "$job" | code_lines | grep -qF 'FLUX_VERSION: "2.8.6"'

  report="$(job_block e2e-report "$PULL_REQUESTS")"
  printf '%s\n' "$report" | code_lines | grep -qF '"verify-release-candidate"'
  printf '%s\n' "$report" | code_lines | grep -qF "IS_RELEASE === 'true' && CANDIDATE_RESULT !== 'success'"

  # gh applies --label after opening a PR. The release label event must replace
  # the initial run and publish a fresh status that includes candidate verify.
  grep -qF "github.event.label.name != 'release'" "$PULL_REQUESTS"
  plan="$(job_block plan "$PULL_REQUESTS")"
  printf '%s\n' "$plan" | code_lines | grep -qF "github.event.label.name == 'release'"
  printf '%s\n' "$report" | code_lines | grep -qF "github.event.label.name == 'release'"
}
