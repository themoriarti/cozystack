#!/usr/bin/env bats

# Contract for the rc-E2E promotion gate and the release-PR opt-in path.
# These tests intentionally pin executable/structural workflow lines, not prose:
# a commented-out gate, label, or body note must never satisfy the contract.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
PROMOTE="$REPO_ROOT/.github/workflows/promote-rc.yaml"
PULL_REQUESTS="$REPO_ROOT/.github/workflows/pull-requests.yaml"
TAGS="$REPO_ROOT/.github/workflows/tags.yaml"
FINALIZE="$REPO_ROOT/.github/workflows/pull-requests-release.yaml"

job_block() {
  awk -v job="  $1:" '
    $0 == job { inside = 1; next }
    /^  [a-z0-9_-]+:$/ { inside = 0 }
    inside' "$2"
}

job_header() {
  job_block "$1" "$2" | awk '
    /^    steps:$/ { exit }
    { print }'
}

input_block() {
  awk -v input="      $1:" '
    $0 == input { inside = 1; print; next }
    inside && /^      [a-zA-Z0-9_-]+:$/ { exit }
    inside { print }' "$2"
}

code_lines() {
  rg -v '^[[:space:]]*#' || true
}

@test "green rc E2E gate is in parse before promote and gates its DAG edge" {
  parse_block="$(job_block parse "$PROMOTE")"
  promote_block="$(job_block promote "$PROMOTE")"
  [ -n "$parse_block" ]
  [ -n "$promote_block" ]

  count="$(printf '%s\n' "$parse_block" | code_lines | rg -cF '      - name: Verify green RC E2E' || true)"
  [ "${count:-0}" -eq 1 ]

  count="$(printf '%s\n' "$parse_block" | code_lines | rg -cF '      actions: read' || true)"
  [ "${count:-0}" -eq 1 ]

  count="$(printf '%s\n' "$promote_block" | code_lines | rg -cF '    needs: parse' || true)"
  [ "${count:-0}" -eq 1 ]

  parse_line="$(code_lines < "$PROMOTE" | rg -n '^  parse:$' | awk -F: 'NR == 1 { print $1 }')"
  promote_line="$(code_lines < "$PROMOTE" | rg -n '^  promote:$' | awk -F: 'NR == 1 { print $1 }')"
  [ -n "$parse_line" ]
  [ -n "$promote_line" ]
  [ "$parse_line" -lt "$promote_line" ]
}

@test "skip_e2e_gate is a boolean emergency override defaulting false" {
  block="$(input_block skip_e2e_gate "$PROMOTE")"
  [ -n "$block" ]

  count="$(printf '%s\n' "$block" | code_lines | rg -cF '      skip_e2e_gate:' || true)"
  [ "${count:-0}" -eq 1 ]

  count="$(printf '%s\n' "$block" | code_lines | rg -cF '        default: false' || true)"
  [ "${count:-0}" -eq 1 ]

  count="$(printf '%s\n' "$block" | code_lines | rg -cF '        type: boolean' || true)"
  [ "${count:-0}" -eq 1 ]

  parse_block="$(job_block parse "$PROMOTE")"
  count="$(printf '%s\n' "$parse_block" | code_lines | rg -cF '        if: ${{ !inputs.skip_e2e_gate }}' || true)"
  [ "${count:-0}" -eq 1 ]
  count="$(printf '%s\n' "$parse_block" | code_lines | rg -cF '        if: ${{ inputs.skip_e2e_gate }}' || true)"
  [ "${count:-0}" -eq 1 ]
}

@test "promote PR keeps release label and does not auto-apply full-e2e" {
  block="$(job_block open-pr "$PROMOTE")"
  [ -n "$block" ]

  count="$(printf '%s\n' "$block" | code_lines | rg -cF -- '--body "$BODY" --label release' || true)"
  [ "${count:-0}" -eq 1 ]

  count="$(printf '%s\n' "$block" | code_lines | rg -cF -- '--label full-e2e' || true)"
  [ "${count:-0}" -eq 0 ]
}

@test "promote PR body carries verified and bypassed E2E status" {
  promote_block="$(job_block promote "$PROMOTE")"
  open_block="$(job_block open-pr "$PROMOTE")"

  count="$(printf '%s\n' "$promote_block" | code_lines | rg -cF '      e2e_verification: ${{ needs.parse.outputs.e2e_verification }}' || true)"
  [ "${count:-0}" -eq 1 ]

  count="$(printf '%s\n' "$open_block" | code_lines | rg -cF '          E2E_VERIFICATION: ${{ needs.promote.outputs.e2e_verification }}' || true)"
  [ "${count:-0}" -eq 1 ]

  count="$(printf '%s\n' "$open_block" | code_lines | rg -cF '            E2E_NOTE="✅ RC full e2e was verified' || true)"
  [ "${count:-0}" -eq 1 ]

  count="$(printf '%s\n' "$open_block" | code_lines | rg -cF '            E2E_NOTE="⚠️ **RC e2e gate bypassed**' || true)"
  [ "${count:-0}" -eq 1 ]

  count="$(printf '%s\n' "$open_block" | code_lines | rg -cF '          ${E2E_NOTE}' || true)"
  [ "${count:-0}" -eq 1 ]
}

@test "release PR E2E is a working manual full-e2e label opt-in" {
  count="$(code_lines < "$PULL_REQUESTS" | rg -cF '    types: [opened, synchronize, reopened, labeled]' || true)"
  [ "${count:-0}" -eq 1 ]

  plan_header="$(job_header plan "$PULL_REQUESTS")"
  count="$(printf '%s\n' "$plan_header" | code_lines | rg -cF "    if: github.event.action != 'labeled' || github.event.label.name == 'full-e2e'" || true)"
  [ "${count:-0}" -eq 1 ]

  resolve_header="$(job_header resolve_assets "$PULL_REQUESTS")"
  count="$(printf '%s\n' "$resolve_header" | code_lines | rg -cF "github.event.label.name == 'full-e2e'" || true)"
  [ "${count:-0}" -eq 1 ]

  e2e_header="$(job_header e2e "$PULL_REQUESTS")"
  count="$(printf '%s\n' "$e2e_header" | code_lines | rg -cF "needs.resolve_assets.result == 'success'" || true)"
  [ "${count:-0}" -eq 1 ]
  count="$(printf '%s\n' "$e2e_header" | code_lines | rg -cF "&& contains(github.event.pull_request.labels.*.name, 'full-e2e')" || true)"
  [ "${count:-0}" -eq 1 ]
}

# ── promote-time website docs contract ──────────────────────────────────────
# The website "update managed apps reference" PR is opened at PROMOTE time from
# the staging branch (via FETCH_REF) instead of only at tag time. These pins are
# executable/structural (code_lines strips comments) so a commented-out step,
# guard, or body line can never satisfy them. The one deliberate exception is the
# tags.yaml backstop-comment pin, which asserts a COMMENT is present.

@test "promote-rc website-docs job depends on parse and promote" {
  block="$(job_block website-docs "$PROMOTE")"
  [ -n "$block" ]

  count="$(printf '%s\n' "$block" | code_lines | rg -cF '    needs: [parse, promote]' || true)"
  [ "${count:-0}" -eq 1 ]

  # It must run after the staging branch exists — website-docs is ordered after
  # promote in the file, and promote is what pushes release-X.Y.Z.
  website_line="$(code_lines < "$PROMOTE" | rg -n '^  website-docs:$' | awk -F: 'NR == 1 { print $1 }')"
  promote_line="$(code_lines < "$PROMOTE" | rg -n '^  promote:$' | awk -F: 'NR == 1 { print $1 }')"
  [ -n "$website_line" ] && [ -n "$promote_line" ]
  [ "$promote_line" -lt "$website_line" ]
}

@test "website-docs fetches docs from the staging branch via FETCH_REF, not the stable tag" {
  block="$(job_block website-docs "$PROMOTE")"
  [ -n "$block" ]

  # The load-bearing invocation shape: update-all pinned to the staging branch.
  count="$(printf '%s\n' "$block" | code_lines | rg -cF 'make update-all RELEASE_TAG="$TAG" FETCH_REF="$SRC_REF"' || true)"
  [ "${count:-0}" -eq 1 ]

  # SRC_REF must be the stable staging branch (which exists at promote time), never
  # the stable tag (which finalize only creates post-merge).
  count="$(printf '%s\n' "$block" | code_lines | rg -cF 'SRC_REF: ${{ needs.parse.outputs.stable_branch }}' || true)"
  [ "${count:-0}" -ge 1 ]
  count="$(printf '%s\n' "$block" | code_lines | rg -cF 'FETCH_REF="${{ needs.parse.outputs.stable_tag }}"' || true)"
  [ "${count:-0}" -eq 0 ]
}

@test "website-docs guards against a website checkout that predates FETCH_REF" {
  block="$(job_block website-docs "$PROMOTE")"
  guard="$(printf '%s\n' "$block" | awk '
    /^      - name: Require FETCH_REF support/ { inside = 1; next }
    /^      - name: / { inside = 0 }
    inside')"
  [ -n "$guard" ]

  # It detects support by probing the website Makefile, and fails loudly when
  # absent — never warn-and-continue into stub-doc generation.
  printf '%s\n' "$guard" | code_lines | rg -qF "grep -q '^FETCH_REF' Makefile"
  printf '%s\n' "$guard" | code_lines | rg -qF 'exit 1'
}

@test "website-docs checkout does not persist credentials (app-token push, extraheader trap)" {
  block="$(job_block website-docs "$PROMOTE")"
  checkout="$(printf '%s\n' "$block" | awk '
    /^      - name: Checkout website repo$/ { inside = 1; next }
    /^      - name: / { inside = 0 }
    inside')"
  [ -n "$checkout" ]

  count="$(printf '%s\n' "$checkout" | code_lines | rg -cF 'persist-credentials: false' || true)"
  [ "${count:-0}" -eq 1 ]
  count="$(printf '%s\n' "$checkout" | code_lines | rg -cF 'repository: cozystack/website' || true)"
  [ "${count:-0}" -eq 1 ]
}

@test "website-docs PR body carries the DO-NOT-MERGE-until-finalize contract" {
  block="$(job_block website-docs "$PROMOTE")"
  # Explicit merge-timing wording in the body the job opens on cozystack/website.
  printf '%s\n' "$block" | code_lines | rg -qF 'DO NOT MERGE until'
}

@test "promote PR body carries a website-docs ✅/⚠️ status line" {
  block="$(job_block open-pr "$PROMOTE")"
  [ -n "$block" ]

  count="$(printf '%s\n' "$block" | code_lines | rg -cF 'WEBSITE_DOCS_RESULT: ${{ needs.website-docs.result }}' || true)"
  [ "${count:-0}" -eq 1 ]
  count="$(printf '%s\n' "$block" | code_lines | rg -cF '          ${WEBSITE_NOTE}' || true)"
  [ "${count:-0}" -eq 1 ]
  # Both outcomes must be expressible.
  printf '%s\n' "$block" | code_lines | rg -qF 'WEBSITE_NOTE="✅'
  printf '%s\n' "$block" | code_lines | rg -qF 'WEBSITE_NOTE="⚠️'
}

@test "tags.yaml update-website-docs documents that it is now the backstop" {
  # Deliberately a COMMENT-presence pin (not code_lines): the backstop status is
  # documented in a comment above the tag-time job so a maintainer reading it
  # knows the promote flow opens the PR earlier.
  grep -qF 'promote-rc.yaml::website-docs' "$TAGS"
  grep -qiF 'backstop' "$TAGS"
}

@test "finalize checkout does not persist credentials so the app-token tag push triggers tags.yaml" {
  block="$(job_block finalize "$FINALIZE")"
  [ -n "$block" ]
  checkout="$(printf '%s\n' "$block" | awk '
    /^      - name: Checkout repo$/ { inside = 1; next }
    /^      - name: / { inside = 0 }
    inside')"
  [ -n "$checkout" ]

  # The one-line root-cause fix. Without persist-credentials:false the checkout
  # persists GITHUB_TOKEN as http.extraheader, which silently defeats the app token
  # each later `git remote set-url` injects onto the tag pushes — and a
  # GITHUB_TOKEN-authenticated push creates no workflow run (anti-recursion), so
  # tags.yaml's stable-tag backstops never fire (v1.6.0's tag never triggered it).
  count="$(printf '%s\n' "$checkout" | code_lines | rg -cF 'persist-credentials: false' || true)"
  [ "${count:-0}" -eq 1 ]
}
