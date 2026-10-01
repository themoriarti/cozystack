#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Contract: a Chainsaw script op whose script carries its own waits gives those
# waits room to fire first. When the op ceiling fires instead, Chainsaw kills
# the shell, the script's own failure message never prints, and a cleanup trap
# never runs (.chainsaw.yaml states the rule above its catch scripts).
#
# The gateway step is held by arithmetic: its polls are `timeout N` prefixes
# and its cleanup deletes run under `timeout -k K N`, so their sum, kill
# grace included, is readable from the text. kubectl's own `--timeout` is not
# counted: it bounds only the wait after the delete request, not discovery or
# the request itself. Only those two spellings are summed: a wait written any
# other way, a `kubectl wait` or a sleep loop, is invisible to the sum.
#
# cozytest.sh's awk parser recognizes only @test blocks and a bare `}` on its
# own line; a `}` at column zero gets `return 0` inserted ahead of it, so the
# helpers below report through stdout only.
#
# Run with: hack/cozytest.sh hack/chainsaw-op-budgets.bats
# -----------------------------------------------------------------------------

GATEWAY_SUITE="hack/e2e-chainsaw/gateway/chainsaw-test.yaml"
GATEWAY_STEP="parent-child-and-route-drive-listener-set"

# Seconds the gateway op keeps above its summed waits for what carries no cap
# of its own: three applies and one label read.
GATEWAY_UNCAPPED=60

# Print the lines of the first `- script:` op inside step $2 of file $1, with
# the op's own indentation, from `- script:` up to the next op or step.
op_lines() {
  awk -v step="$2" '
    $0 ~ "^[[:space:]]*- name: " step "[[:space:]]*$" { instep = 1; next }
    instep && !inop && /^[[:space:]]*- script:[[:space:]]*$/ {
      match($0, /^[[:space:]]*/); opindent = RLENGTH; inop = 1; print; next
    }
    inop && /[^[:space:]]/ {
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= opindent) exit
    }
    inop { print }
    instep && /^---/ { exit }
  ' "$1"
}

# Print the op timeout in seconds of the op in $1 (op_lines output), or
# nothing when it states none in minutes or seconds.
op_timeout_seconds() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*timeout:[[:space:]]*[0-9]+m[[:space:]]*$/ { match($0, /[0-9]+/); print substr($0, RSTART, RLENGTH) * 60; exit }
    /^[[:space:]]*timeout:[[:space:]]*[0-9]+s[[:space:]]*$/ { match($0, /[0-9]+/); print substr($0, RSTART, RLENGTH); exit }
    /^[[:space:]]*content:/ { exit }
  '
}

# Print the op's script, dedented, without the content key.
op_content() {
  printf '%s\n' "$1" | awk '
    !incontent && /^[[:space:]]*content:[[:space:]]*\|[[:space:]]*$/ { match($0, /^[[:space:]]*/); keyindent = RLENGTH; incontent = 1; next }
    incontent && /[^[:space:]]/ {
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= keyindent) exit
      if (!bodyindent) bodyindent = RLENGTH
    }
    incontent { print substr($0, bodyindent + 1) }
  '
}

@test "the gateway listener-set op outlasts the waits inside it" {
    gw_op=$(op_lines "$GATEWAY_SUITE" "$GATEWAY_STEP")
    [ -n "$gw_op" ] || { echo "no script op found in step $GATEWAY_STEP of $GATEWAY_SUITE" >&2; exit 1; }
    gw_timeout=$(op_timeout_seconds "$gw_op")
    case "$gw_timeout" in ''|*[!0-9]*) echo "the $GATEWAY_STEP op states no timeout in m or s (got '${gw_timeout}')" >&2; exit 1 ;; esac
    gw_body=$(op_content "$gw_op")
    gw_polls=$(printf '%s\n' "$gw_body" | grep -oE '^[[:space:]]*timeout +[0-9]+' | grep -oE '[0-9]+$' || true)
    gw_n=$(printf '%s\n' "$gw_polls" | grep -c . || true)
    [ "$gw_n" -ge 5 ] || { echo "found ${gw_n} capped polls in $GATEWAY_STEP, expected at least 5; the extractor is reading the wrong lines" >&2; exit 1; }
    gw_deletes=$(printf '%s\n' "$gw_body" | grep -E '(^|[[:space:]])kubectl .* delete ' | grep -oE '(^|[[:space:]])timeout -k [0-9]+ [0-9]+ kubectl ' | awk '{ print $3 + $4 }' || true)
    gw_sum=0
    for gw_w in $gw_polls $gw_deletes; do gw_sum=$(( gw_sum + gw_w )); done
    [ $(( gw_timeout - gw_sum )) -ge "$GATEWAY_UNCAPPED" ] || {
        echo "the $GATEWAY_STEP op allows ${gw_timeout}s; its polls ($(printf '%s ' $gw_polls)) and cleanup deletes ($(printf '%s ' $gw_deletes)) may wait ${gw_sum}s" >&2
        echo "it must keep ${GATEWAY_UNCAPPED}s above them for the uncapped applies and reads" >&2
        exit 1
    }
}

@test "every delete in the gateway listener-set cleanup is bounded as a whole" {
    # A tenant delete blocks until its child namespaces drain, and a stalled
    # API request blocks with no bound at all, so a delete not wrapped in an
    # outer timeout is a wait the op sum above cannot see.
    gw_op=$(op_lines "$GATEWAY_SUITE" "$GATEWAY_STEP")
    gw_deletes=$(op_content "$gw_op" | grep -E '(^|[[:space:]])kubectl .* delete ' || true)
    [ -n "$gw_deletes" ] || { echo "no kubectl delete found in $GATEWAY_STEP; the cleanup this test reasons about is gone" >&2; exit 1; }
    gw_bad=$(printf '%s\n' "$gw_deletes" | grep -vE '(^|[[:space:]])timeout -k [0-9]+ [0-9]+ kubectl ' || true)
    [ -z "$gw_bad" ] || { echo "deletes in $GATEWAY_STEP whose wait has no bound:" >&2; printf '%s\n' "$gw_bad" >&2; exit 1; }
}

@test "the gateway listener-set cleanup deletes the parent only once the child is gone" {
    # A parent deleted while its child is still uninstalling wedges the
    # parent's cleanup, so a child delete that ran into its bound must leave
    # the parent alone.
    gw_op=$(op_lines "$GATEWAY_SUITE" "$GATEWAY_STEP")
    gw_order=$(op_content "$gw_op" | awk '
      /^[[:space:]]*if timeout -k [0-9]+ [0-9]+ kubectl .* delete tenant rchild .*; then[[:space:]]*$/ { guarded = 1; next }
      guarded && /[^[:space:]]/ { print (/delete tenant rparent/ ? "ok" : "unguarded"); exit }
      /delete tenant rparent/ { print "unguarded"; exit }
    ')
    [ "$gw_order" = ok ] || { echo "the rparent delete in $GATEWAY_STEP does not sit directly under a successful rchild delete (got '${gw_order}')" >&2; exit 1; }
}

@test "a failed tenant delete in the gateway cleanup fails the step with its own error" {
    # A tenant left in place is one every later suite inherits, so
    # the step must say so and fail rather than pass with the leak.
    gw_dir=$(mktemp -d)
    op_content "$(op_lines "$GATEWAY_SUITE" "$GATEWAY_STEP")" | awk '/^cleanup\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' > "$gw_dir/cleanup.sh"
    grep -q 'delete tenant rchild' "$gw_dir/cleanup.sh" || { echo "no cleanup() with the rchild delete found in $GATEWAY_STEP" >&2; exit 1; }
    # The stub fails the delete of the tenant named in STUB_FAIL_TENANT with a
    # Forbidden error, which is not the bound firing, and logs every delete.
    printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$(dirname "$0")/calls"' 'case "$*" in *"delete tenant $STUB_FAIL_TENANT "*) echo "Error from server (Forbidden): stubbed" >&2; exit 3 ;; esac' > "$gw_dir/kubectl"
    chmod +x "$gw_dir/kubectl"
    for gw_tenant in rchild rparent; do
        : > "$gw_dir/calls"
        gw_rc=0
        gw_out=$(PATH="$gw_dir:$PATH" STUB_FAIL_TENANT="$gw_tenant" sh -c '. "$1/cleanup.sh"; ns=tenant-test; cleanup' sh "$gw_dir" 2>&1) || gw_rc=$?
        [ "$gw_rc" -ne 0 ] || { printf '%s\n' "$gw_out" >&2; echo "cleanup exited 0 with the $gw_tenant delete failed" >&2; exit 1; }
        case "$gw_out" in *"Forbidden"*"$gw_tenant delete exited 3"*"rparent is left in tenant-test"*) ;; *) printf '%s\n' "$gw_out" >&2; echo "with the $gw_tenant delete failed, the output does not carry kubectl's error, its exit status and the tenant left behind" >&2; exit 1 ;; esac
        if [ "$gw_tenant" = rchild ] && grep -q 'delete tenant rparent' "$gw_dir/calls"; then echo "the parent was deleted although the child delete failed" >&2; exit 1; fi
    done
    rm -rf "$gw_dir"
}
