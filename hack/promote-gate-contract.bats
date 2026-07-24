#!/usr/bin/env bats

# Contract for the rc-E2E promotion gate and the release-PR opt-in path.
# These tests intentionally pin executable/structural workflow lines, not prose:
# a commented-out gate, label, or body note must never satisfy the contract.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
PROMOTE="$REPO_ROOT/.github/workflows/promote-rc.yaml"
PULL_REQUESTS="$REPO_ROOT/.github/workflows/pull-requests.yaml"

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
