#!/usr/bin/env bats
# EXIT-TRAP DEBT: 1 -- see hack/bats-no-exit-trap.bats; lower it as the traps go, delete it at zero.
# -----------------------------------------------------------------------------
# Unit tests for the pure decision/parsing helpers in
# hack/e2e-capture-dataplane.sh -- specifically the LoadBalancer-datapath
# section, which fires for a Service type=LoadBalancer whose external IP is
# unreachable while its backend stays Ready (the NotReady-pod path never sees
# this case). Only the pure logic is unit-testable here:
#
#   - lb_filter_services      -- keep only LoadBalancer rows with an ingress IP;
#   - lb_first_ready_endpoint -- pick the first addressed, non-NotReady endpoint;
#   - lb_announcer_node       -- the speaker node of the most recent announce;
#   - lb_capture_decision     -- capture when probes failed, skip when one
#                               succeeded or none ran, unknown when none could run.
#   - pod_filter_affected     -- retain scheduled NotReady pods even without IPs.
#
# The tests come in two shapes, and neither needs a cluster.
#
# The first sources the script with E2E_CAPTURE_DATAPLANE_LIB set, which the
# sourcing guard honours by defining the helpers and returning before it touches
# $1 or runs any capture. Those tests call the pure helpers directly and assert
# with `[ ... ]`, matching this repo's plain-shell bats convention (no `run`
# helper). Mock IPs use the RFC 5737 / RFC 3849 documentation ranges.
#
# The second runs the script as a subprocess against a stub kubectl on PATH --
# one that hangs, refuses, or answers in part -- and reads what it wrote. That
# reaches the capture body itself, which no amount of sourcing can: the bounds,
# the notes and the difference between "nothing is there" and "the read never
# said" are all properties of the running script, and several of them are only
# observable in the artifact it leaves behind.
#
# A stub has to reach the branch a test is about. Several of these tests walk
# the LB heavy-capture path, which only runs when the probe reports the address
# unreachable, so their stubs answer `nc -z` with a failure on purpose. A stub
# that stops short leaves the test green against every implementation.
#
# Title syntax constraints (inherited from cozytest.sh's awk parser):
#   - Titles delimited by ASCII double quotes; embedded quotes truncate.
#   - Only [A-Za-z0-9] from the title survives into the function name, so keep
#     titles distinctive in their alphanumeric run.
#
# Run with: hack/cozytest.sh hack/capture-dataplane.bats
#           (or `bats hack/capture-dataplane.bats` if the bats binary is
#           installed; cozytest.sh is the CI path.)
# -----------------------------------------------------------------------------

HACK_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")" && pwd)"
SCRIPT="$HACK_DIR/e2e-capture-dataplane.sh"

# Load the pure helpers. The guard returns before the capture body, so this is
# side-effect-free and needs no cluster.
E2E_CAPTURE_DATAPLANE_LIB=1
# shellcheck source=/dev/null
. "$SCRIPT"

@test "pod_filter_affected keeps a scheduled NotReady pod without a podIP" {
  rows="$(printf '%s\n' \
    'tenant|no-ip||node-a|False|Pending' \
    'tenant|with-ip|192.0.2.80|node-b|False|Running')"

  out="$(printf '%s\n' "$rows" | pod_filter_affected)"

  [ "$(printf '%s\n' "$out" | awk 'END { print NR }')" -eq 2 ]
  printf '%s\n' "$out" | awk '$0 == "tenant|no-ip||node-a|False|Pending" { found = 1 } END { exit !found }'
}

@test "pod_filter_affected drops Ready unscheduled and terminal pods" {
  rows="$(printf '%s\n' \
    'tenant|ready|192.0.2.81|node-a|True|Running' \
    'tenant|unscheduled|||False|Pending' \
    'tenant|succeeded|192.0.2.82|node-b|False|Succeeded' \
    'tenant|failed|192.0.2.83|node-b|False|Failed')"

  [ -z "$(printf '%s\n' "$rows" | pod_filter_affected)" ]
}

@test "runtime checks LoadBalancers when there are no affected pods" {
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  calls="$tmp/kubectl.calls"
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/kubectl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_KUBECTL_CALLS"
exit 0
EOF
  chmod +x "$tmp/bin/kubectl"

  MOCK_KUBECTL_CALLS="$calls" PATH="$tmp/bin:$PATH" \
    "$SCRIPT" "$tmp/out" > "$tmp/stdout" 2>&1

  awk '$0 ~ /^get svc -A / { found = 1 } END { exit !found }' "$calls"
  awk 'index($0, "checking LoadBalancers independently") { found = 1 } END { exit !found }' "$tmp/stdout"
  awk 'index($0, "no Service type=LoadBalancer") { found = 1 } END { exit !found }' "$tmp/stdout"
}

@test "lb_filter_services keeps only LoadBalancer rows that have an ingress IP" {
  rows="$(printf '%s\n' \
    'tenant|app|LoadBalancer|192.0.2.50|80|31000|Cluster' \
    'kube-system|kube-dns|ClusterIP||53||Cluster' \
    'tenant|pending|LoadBalancer||443|31443|Local' \
    'tenant|db|LoadBalancer|192.0.2.51|5432|31543|Local')"

  out="$(printf '%s\n' "$rows" | lb_filter_services)"

  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ]
  printf '%s\n' "$out" | grep -q '^tenant|app|LoadBalancer|192.0.2.50|'
  printf '%s\n' "$out" | grep -q '^tenant|db|LoadBalancer|192.0.2.51|'
  # `! cmd` is vacuous under cozytest's `set -e` (errexit is suppressed for a
  # `!`-negated pipeline), so a filter regression that let these rows through
  # would not fail the test. Assert the absence via `if cmd; then ...; false`.
  if printf '%s\n' "$out" | grep -q 'kube-dns'; then echo "FAIL: lb_filter_services must drop the kube-dns row"; false; fi
  if printf '%s\n' "$out" | grep -q 'pending'; then echo "FAIL: lb_filter_services must drop the pending (no external IP) row"; false; fi
}

@test "lb_first_ready_endpoint picks the first addressed endpoint that is not NotReady" {
  eps="$(printf '%s\n' \
    '||tenant|virt-launcher-x|true' \
    '192.0.2.60|worker-1|tenant|virt-launcher-x|false' \
    '192.0.2.61|worker-2|tenant|virt-launcher-y|true' \
    '192.0.2.62|worker-3|tenant|virt-launcher-z|true')"

  out="$(printf '%s\n' "$eps" | lb_first_ready_endpoint)"

  [ "$out" = "192.0.2.61|worker-2|tenant|virt-launcher-y" ]
}

@test "lb_first_ready_endpoint treats a blank ready column as ready" {
  eps="$(printf '%s\n' '192.0.2.70|worker-9|tenant|app-0|')"

  out="$(printf '%s\n' "$eps" | lb_first_ready_endpoint)"

  [ "$out" = "192.0.2.70|worker-9|tenant|app-0" ]
}

@test "lb_announcer_node returns the speaker node of the most recent announce" {
  logs="$(printf '%s\t%s\n' \
    'node-a' '{"event":"serviceAnnounced","ips":["192.0.2.50"],"node":"node-a"}' \
    'node-b' '{"event":"serviceAnnounced","ips":["192.0.2.50"],"node":"node-b"}')"

  out="$(printf '%s\n' "$logs" | lb_announcer_node '192.0.2.50')"

  [ "$out" = "node-b" ]
}

@test "lb_announcer_node ignores withdraw lines and announces for other IPs" {
  logs="$(printf '%s\t%s\n' \
    'node-x' '{"event":"serviceAnnounced","ips":["198.51.100.9"],"node":"node-x"}' \
    'node-a' '{"event":"serviceAnnounced","ips":["192.0.2.50"],"node":"node-a"}' \
    'node-b' '{"event":"serviceWithdrawn","ips":["192.0.2.50"],"node":"node-b"}' \
    'node-c' '{"event":"serviceAnnounced","ips":["192.0.2.50"],"node":"node-c"}')"

  out="$(printf '%s\n' "$logs" | lb_announcer_node '192.0.2.50')"

  [ "$out" = "node-c" ]
}

@test "lb_announcer_node emits nothing when the IP was never announced" {
  logs="$(printf '%s\t%s\n' \
    'node-a' '{"event":"serviceAnnounced","ips":["198.51.100.9"],"node":"node-a"}')"

  out="$(printf '%s\n' "$logs" | lb_announcer_node '192.0.2.50')"

  [ -z "$out" ]
}

@test "lb_announcer_node excludes a node whose last own event is a withdraw" {
  # Case A: node-a announces the IP then withdraws it and never re-announces.
  # Its last own IP-event is the withdraw, so it is NOT the current announcer and
  # nothing must be reported. The pre-polish logic kept node-a (a withdraw did
  # not retract a prior announce), so this pins the failover fix.
  logs="$(printf '%s\t%s\n' \
    'node-a' '{"event":"serviceAnnounced","ips":["192.0.2.50"],"node":"node-a"}' \
    'node-a' '{"event":"serviceWithdrawn","ips":["192.0.2.50"],"node":"node-a"}')"

  out="$(printf '%s\n' "$logs" | lb_announcer_node '192.0.2.50')"

  [ -z "$out" ]
}

@test "lb_announcer_node ignores a stale owner that appears later in concat order" {
  # Case B: node-c is the true current owner (announce, never withdrawn). Later
  # in the input -- speaker logs are concatenated per-pod, NOT globally time-
  # sorted -- a stale node-a announce+withdraw block appears. node-a's last own
  # event is a withdraw, so the announcer is node-c, NOT the later-in-input
  # node-a. The pre-polish logic returned node-a (most recent announce by concat
  # order), so this pins robustness to concat order.
  logs="$(printf '%s\t%s\n' \
    'node-c' '{"event":"serviceAnnounced","ips":["192.0.2.50"],"node":"node-c"}' \
    'node-a' '{"event":"serviceAnnounced","ips":["192.0.2.50"],"node":"node-a"}' \
    'node-a' '{"event":"serviceWithdrawn","ips":["192.0.2.50"],"node":"node-a"}')"

  out="$(printf '%s\n' "$logs" | lb_announcer_node '192.0.2.50')"

  [ "$out" = "node-c" ]
}

@test "lb_announcer_node matches the IP as a whole token not a substring" {
  # Case C: querying 192.0.2.5 must NOT match a 192.0.2.50 announce (the
  # pre-polish index()/substring match returned node-d here). The exact 192.0.2.5
  # announce on node-e is matched and wins.
  logs="$(printf '%s\t%s\n' \
    'node-d' '{"event":"serviceAnnounced","ips":["192.0.2.50"],"node":"node-d"}' \
    'node-e' '{"event":"serviceAnnounced","ips":["192.0.2.5"],"node":"node-e"}')"

  no_substr="$(printf '%s\n' "$logs" | lb_announcer_node '192.0.2.5')"
  no_match="$(printf '%s\t%s\n' \
    'node-d' '{"event":"serviceAnnounced","ips":["192.0.2.50"],"node":"node-d"}' \
    | lb_announcer_node '192.0.2.5')"

  [ "$no_substr" = "node-e" ]
  [ -z "$no_match" ]
}

@test "lb_capture_decision returns capture when every probe failed" {
  [ "$(printf 'fail\nfail\nfail\n' | lb_capture_decision)" = "capture" ]
  [ "$(printf 'fail\n' | lb_capture_decision)" = "capture" ]
}

@test "lb_capture_decision returns skip when any probe succeeded" {
  [ "$(printf 'fail\nok\nfail\n' | lb_capture_decision)" = "skip" ]
  [ "$(printf 'ok\n' | lb_capture_decision)" = "skip" ]
}

@test "lb_capture_decision returns skip when no probe ran at all" {
  [ "$(printf '' | lb_capture_decision)" = "skip" ]
}

@test "lb_budget_ok yes below the cap and no once it is reached" {
  [ "$(lb_budget_ok 0 6)" = "yes" ]
  [ "$(lb_budget_ok 5 6)" = "yes" ]
  [ "$(lb_budget_ok 6 6)" = "no" ]
  [ "$(lb_budget_ok 7 6)" = "no" ]
}

@test "capture budget counts captured LBs so a late broken LB is still captured" {
  # The MAX_LBS cap must bound LBs actually CAPTURED, not LBs enumerated: reachable
  # (skipped) LBs must not consume the budget, so a broken LB enumerated after many
  # reachable ones is still characterised. This mirrors the per-LB loop in
  # capture_lb_datapath, which only consults lb_budget_ok / increments the counter
  # on the capture branch -- here driven by a fixed decision sequence so no cluster
  # is needed. With the pre-polish "increment per enumerated LB" logic and max=2,
  # the loop would have broken at the 3rd LB and never reached the broken one.
  max=2
  captured=0
  last=""
  for decision in skip skip skip skip skip capture; do
    if [ "$decision" != "capture" ]; then
      last="skip"
      continue
    fi
    if [ "$(lb_budget_ok "$captured" "$max")" != "yes" ]; then
      last="dropped"
      continue
    fi
    captured=$((captured + 1))
    last="captured"
  done

  [ "$captured" -eq 1 ]
  [ "$last" = "captured" ]
}

@test "capture budget stops after the cap worth of broken LBs" {
  # Once MAX_LBS broken LBs are captured, further unreachable LBs are not
  # characterised (left to the outer wall-clock backstop). max=2, three broken.
  max=2
  captured=0
  dropped=0
  for decision in capture capture capture; do
    if [ "$(lb_budget_ok "$captured" "$max")" != "yes" ]; then
      dropped=$((dropped + 1))
      continue
    fi
    captured=$((captured + 1))
  done

  [ "$captured" -eq 2 ]
  [ "$dropped" -eq 1 ]
}

# -----------------------------------------------------------------------------
# Behavioural: the reads are bounded, and a bound that fires says so.
#
# These run the script rather than sourcing it, so they need the guard NOT set;
# the runner is invoked as a subprocess, which leaves this file's sourced copy
# untouched. A stub kubectl that never returns stands in for the case the bounds
# exist for -- an apiserver that hangs rather than refuses. The bounds are read
# from the environment so the test does not have to wait out the real ones.
# -----------------------------------------------------------------------------

# Scratch dir with a kubectl that hangs forever, mimicking an apiserver that
# accepts the connection and never answers.
dp_hanging_kubectl_dir() {
  _d=$(mktemp -d)
  mkdir -p "$_d/bin"
  printf '#!/bin/sh\nsleep 300\n' >"$_d/bin/kubectl"
  chmod +x "$_d/bin/kubectl"
  printf '%s' "$_d"
}

@test "a hung cluster-wide pod list is cut off rather than eating the envelope" {
  d=$(dp_hanging_kubectl_dir)
  # Without a per-read bound the first list runs until the CALLER's backstop and
  # the script writes nothing at all, so the outer timeout here stands in for
  # that backstop: reaching it means the read was never bounded.
  PATH="$d/bin:$PATH" COZY_DATAPLANE_LIST_TIMEOUT=2 COZY_DATAPLANE_READ_TIMEOUT=2 \
    timeout 20 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  grep -q 'cut off' "$d/log"
  rm -rf "$d"
}

@test "the script survives a hung apiserver and still reaches its own end" {
  # This stub ANSWERS the cluster-wide pod list and hangs on everything after
  # it, so the walk over affected pods actually runs. A stub that hangs on every
  # call leaves that list empty, skips the whole branch, and exercises two of
  # the nine bounded reads while looking like it covered all of them: an
  # unbounded read added inside the branch would not turn it red.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  cat >"$d/bin/kubectl" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case $a in
    pods) echo 'tenant-test|wedged|10.0.0.1|node-a|False|Running'; exit 0 ;;
  esac
done
sleep 300
STUB
  chmod +x "$d/bin/kubectl"
  PATH="$d/bin:$PATH" COZY_DATAPLANE_LIST_TIMEOUT=1 COZY_DATAPLANE_READ_TIMEOUT=1 \
    timeout 90 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  # The closing line prints only if control reached it, which it cannot do while
  # blocked on a read along the way.
  grep -q 'skipping LB-datapath capture' "$d/log"
  # And the per-pod branch was really walked, so the reads inside it are covered
  # rather than assumed.
  grep -q 'looking up the pod matching' "$d/log"
  rm -rf "$d"
}

@test "a read that failed instantly is not reported as a timeout" {
  # The bounds produce 124 or 137 and nothing else, so any other status is
  # kubectl answering -- refused, denied, no such kind. Naming a timeout there
  # puts a cause in the artifact that never happened, and because these reads
  # send stderr to a sink rather than the log, that false cause would be the
  # only thing a reader gets. This is the path the hung-apiserver tests above
  # never reach.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  printf '#!/bin/sh\necho "The connection to the server was refused" >&2\nexit 1\n' >"$d/bin/kubectl"
  chmod +x "$d/bin/kubectl"
  PATH="$d/bin:$PATH" timeout 20 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  # Scoped to this script's own note lines: a bare grep over the whole log would
  # go red on any future line that merely contains the word.
  if grep '^\[capture-dataplane\]' "$d/log" | grep -q 'timeout'; then
    echo "an instant failure was reported as a timeout:"
    cat "$d/log"
    exit 1
  fi
  # It must still say the read produced nothing, and say why, or the silence
  # this suite exists to remove comes back.
  grep -q 'kubectl exited 1' "$d/log"
  # And that kubectl's own words come with it: the exit code alone reads the
  # same whether the message was captured or dropped on the floor.
  grep -q 'refused' "$d/out/capture-notes.txt"
  rm -rf "$d"
}

@test "a kubectl error cannot forge a second verdict line in the log" {
  # log() carries kubectl's stderr now, and under /bin/sh echo would expand a
  # literal backslash-n in it into a real newline, printing a second
  # "[capture-dataplane] ..." line that reads as this script's own finding. The
  # jsonpath in these reads contains {"\n"} and kubectl quotes the expression
  # back on a parse error, so this needs no malice to happen.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  printf '#!/bin/sh\nprintf %%s "unauthorized: x\\\\n[capture-dataplane] no scheduled NotReady pods -- nothing was wrong" >&2\nexit 1\n' >"$d/bin/kubectl"
  chmod +x "$d/bin/kubectl"
  PATH="$d/bin:$PATH" timeout 20 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  # Exactly one note about the pod list, and the forged sentence must not be
  # sitting on a line of its own wearing this script's prefix.
  # The note must exist before its shape means anything: a stub that stopped
  # short of the read would satisfy a purely negative assertion.
  grep -q 'listing pods failed' "$d/log"
  forged=$(grep -c '^\[capture-dataplane\] no scheduled NotReady pods -- nothing was wrong' "$d/log" || true)
  if [ "$forged" -ne 0 ]; then
    echo "kubectl stderr forged a verdict line:"
    cat "$d/log"
    exit 1
  fi
  rm -rf "$d"
}

@test "a node with no matching pod is not reported as a failed read" {
  # The per-node lookups ask for one pod by label on one node, and the ordinary
  # answer is that there is none -- a node without a cilium-agent is the case
  # this capture exists for. That answer must not arrive as a failed read now
  # that a non-zero status carries a note.
  #
  # Reaching this path needs a kubectl that ANSWERS the cluster-wide list with
  # one affected pod; the other tests never get here because their list fails
  # first and leaves nothing to walk.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  cat >"$d/bin/kubectl" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case $a in
    pods) echo 'tenant-test|wedged|10.0.0.1|node-a|False|Running'; exit 0 ;;
  esac
done
# The behaviour under test: client-go's evalArray has no allowMissingKeys
# escape, so indexing [0] into an empty list is a hard error and kubectl exits
# 1, while [*] returns empty and exits 0. Without this arm the stub answers 0
# to both forms and the test cannot see the difference it exists to pin.
case "$*" in
  *'items[0]'*) echo 'error: array index out of bounds: index 0, length 0' >&2; exit 1 ;;
esac
exit 0
STUB
  chmod +x "$d/bin/kubectl"
  PATH="$d/bin:$PATH" timeout 30 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  if grep -q 'looking up the pod matching' "$d/log"; then
    echo "an absent pod was reported as a failed read:"
    grep 'looking up the pod matching' "$d/log"
    exit 1
  fi
  if grep -q 'looking up an ovn-central replica' "$d/log"; then
    echo "an absent ovn-central was reported as a failed read:"
    grep 'looking up an ovn-central replica' "$d/log"
    exit 1
  fi
  # Positive anchors, because everything above is a negative: a stub that
  # stopped short of the walk would satisfy all of it while asserting nothing.
  # These are the lines the path is supposed to produce when it does run.
  grep -q 'no cilium-agent pod found on node node-a' "$d/out/node-node-a.txt"
  grep -q 'no ovn-central pod in' "$d/log"
  rm -rf "$d"
}

@test "the same per-node pod lookup is asked once" {
  # Each repeat costs its own bound against an apiserver that hangs, so a lookup
  # asked three times per pod spends the caller's envelope on re-asking instead
  # of on more pods. The stub records every per-node lookup it is given.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  cat >"$d/bin/kubectl" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case $a in
    pods) echo 'tenant-test|wedged|10.0.0.1|node-a|False|Running'; exit 0 ;;
  esac
done
case "$*" in
  *--field-selector*) echo "$*" >>"$STUB_CALLS" ;;
esac
exit 0
STUB
  chmod +x "$d/bin/kubectl"
  STUB_CALLS="$d/calls" PATH="$d/bin:$PATH" timeout 60 "$SCRIPT" "$d/out" >/dev/null 2>&1 || true
  [ -s "$d/calls" ]
  dups=$(sort "$d/calls" | uniq -d | wc -l | tr -d ' ')
  if [ "$dups" -ne 0 ]; then
    echo "the same lookup was issued more than once:"
    sort "$d/calls" | uniq -c | sort -rn | head -5
    exit 1
  fi
  rm -rf "$d"
}

@test "an unanswered pod list is not reported as a cluster with nothing wrong" {
  # The empty-list branch used to print the same line whether the list said
  # "nothing is affected" or never answered, directly under the note saying the
  # read had failed.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  printf '#!/bin/sh\nexit 1\n' >"$d/bin/kubectl"
  chmod +x "$d/bin/kubectl"
  PATH="$d/bin:$PATH" timeout 20 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  if grep -q 'no scheduled NotReady pods' "$d/log"; then
    echo "a failed list was reported as nothing being affected:"
    cat "$d/log"
    exit 1
  fi
  grep -q 'whether any pod is affected is unknown' "$d/log"
  rm -rf "$d"
}

@test "an unanswered ovn-central lookup is not reported as a cluster without it" {
  # Mirror of the pod-list case: the note saying the lookup failed used to sit
  # directly above a line asserting there is no ovn-central, which the script
  # never observed.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  cat >"$d/bin/kubectl" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case $a in
    pods) echo 'tenant-test|wedged|10.0.0.1|node-a|False|Running'; exit 0 ;;
  esac
done
case "$*" in
  *'app=ovn-central'*) echo 'Error from server (Forbidden): pods is forbidden' >&2; exit 1 ;;
esac
exit 0
STUB
  chmod +x "$d/bin/kubectl"
  PATH="$d/bin:$PATH" timeout 60 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  if grep -q 'no ovn-central pod in' "$d/log"; then
    echo "a failed lookup was reported as the cluster not running ovn-central:"
    cat "$d/log"
    exit 1
  fi
  # The distinctive form: 'is unknown' alone also matches the Service-list note.
  grep -q 'runs ovn-central is unknown' "$d/log"
  rm -rf "$d"
}

@test "an unanswered service list is not reported as a cluster without LoadBalancers" {
  # Third instance of the same rule, and the read this PR's stated purpose names
  # directly: an unanswered list must not be reported as an empty one.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  cat >"$d/bin/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
  *'get svc'*) echo 'Error from server (Forbidden): services is forbidden' >&2; exit 1 ;;
esac
exit 0
STUB
  chmod +x "$d/bin/kubectl"
  PATH="$d/bin:$PATH" timeout 30 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  if grep -q 'no Service type=LoadBalancer' "$d/log"; then
    echo "a failed service list was reported as a cluster without LoadBalancers:"
    cat "$d/log"
    exit 1
  fi
  grep -q 'whether any LoadBalancer needs capturing is unknown' "$d/log"
  rm -rf "$d"
}

@test "a partially answered service list is not captured as a complete one" {
  # A list can fail after emitting rows: a bound firing mid-stream leaves output
  # on stdout and 124 in $?. Gating the note on an empty result would let that
  # partial inventory be captured with nothing saying it was partial.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  cat >"$d/bin/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
  *'get svc'*)
    echo 'tenant|web|LoadBalancer|192.0.2.10|80|30080|Cluster'
    exit 1 ;;
esac
exit 0
STUB
  chmod +x "$d/bin/kubectl"
  PATH="$d/bin:$PATH" timeout 30 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  # It must both proceed with what it got and say the list did not finish.
  grep -q 'probing 1 LoadBalancer service' "$d/log"
  if ! grep -q 'listing services' "$d/log"; then
    echo "a partial service list was captured with no note that it failed:"
    cat "$d/log"
    exit 1
  fi
  rm -rf "$d"
}

@test "a note does not claim a step was skipped when the step runs" {
  # A lookup can fail after naming what it was asked for. Both of these notes
  # used to state the consequence unconditionally, so the log said the OVN dump
  # was skipped and the announcer unresolved while both were being produced from
  # the partial answer.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  cat >"$d/bin/kubectl" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case $a in
    pods) echo 'tenant-test|wedged|10.0.0.1|node-a|False|Running'; exit 0 ;;
  esac
done
case "$*" in
  *'app=ovn-central'*) echo 'ovn-central-0'; echo 'boom' >&2; exit 1 ;;
esac
exit 0
STUB
  chmod +x "$d/bin/kubectl"
  PATH="$d/bin:$PATH" timeout 60 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  # It named a replica, so the dump ran; the note must not say it was skipped.
  [ -f "$d/out/ovn-lflows.txt" ]
  # Greps the wording the skip branches actually use, not a phrase that only
  # existed while this was being written: a dead string can never appear, so the
  # assertion could never fire.
  if grep -q 'skipping OVN logical-flow dump' "$d/log"; then
    echo "the log says the dump was skipped while the dump ran:"
    cat "$d/log"
    exit 1
  fi
  rm -rf "$d"
}

@test "a partially answered pod list is not called unanswered" {
  # The list can fail after emitting rows. If everything it named is Ready the
  # affected set is empty and the status is non-zero, which is the same pair of
  # conditions a total failure produces -- so this branch must not assert what
  # the read did, only what is left unknown.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  cat >"$d/bin/kubectl" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case $a in
    pods) echo 'tenant-test|healthy|10.0.0.9|node-a|True|Running'; exit 1 ;;
  esac
done
exit 0
STUB
  chmod +x "$d/bin/kubectl"
  PATH="$d/bin:$PATH" timeout 30 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  # Both assertions are positive because the wording they pin is the whole
  # point: a branch that described the read instead would not emit either line.
  grep -q 'whatever it did not name is missing' "$d/log"
  grep -q 'whether any pod is affected is unknown' "$d/log"
  rm -rf "$d"
}

@test "a cut-off node lookup is not written into the artifact as an absent pod" {
  # The artifact is what a reader opens out of the cozyreport bundle, and it is
  # where "(no cilium-agent pod found)" used to be written for a lookup that
  # never answered. Bounding that read is what made this reachable: unbounded,
  # the script hung until the caller's backstop killed it and no file was
  # written at all, so the bound turned "no artifact" into "an artifact with a
  # claim in it".
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  cat >"$d/bin/kubectl" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case $a in
    pods) echo 'tenant-test|wedged|10.0.0.1|node-a|False|Running'; exit 0 ;;
  esac
done
case "$*" in
  *--field-selector*spec.nodeName*) sleep 300 ;;
esac
exit 0
STUB
  chmod +x "$d/bin/kubectl"
  PATH="$d/bin:$PATH" COZY_DATAPLANE_LIST_TIMEOUT=1 COZY_DATAPLANE_READ_TIMEOUT=1 \
    timeout 90 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  [ -f "$d/out/node-node-a.txt" ]
  if grep -q 'no cilium-agent pod found' "$d/out/node-node-a.txt"; then
    echo "a cut-off lookup was recorded as an absent pod:"
    cat "$d/out/node-node-a.txt"
    exit 1
  fi
  grep -q 'could not determine whether a cilium-agent runs' "$d/out/node-node-a.txt"
  rm -rf "$d"
}

@test "a memo hit reports the same answer as the miss that filled it" {
  # The status has to survive the memo. Every caller reads pod_on_node through a
  # command substitution, so a status kept in a variable dies with that subshell
  # and every hit then looks like a lookup that never answered -- the same node
  # getting <none> from the miss and <unknown> from the hit, in one bundle.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  cat >"$d/bin/kubectl" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case $a in
    pods) echo 'tenant-test|wedged|10.0.0.1|node-a|False|Running'; exit 0 ;;
    svc) echo 'tenant|web|LoadBalancer|192.0.2.10|80|30080|Cluster'; exit 0 ;;
    endpointslices) echo '10.0.0.1|node-a|tenant-test|wedged|true'; exit 0 ;;
  esac
done
case "$*" in
  # Answers, and answers "there is no such pod" -- status 0, empty output.
  *'app=ovs'*) exit 0 ;;
  *'k8s-app=cilium'*) echo 'cilium-xyz'; exit 0 ;;
  *'app=kube-ovn-cni'*) echo 'cni-abc'; exit 0 ;;
  # The LB must probe UNREACHABLE, or the heavy capture is skipped and
  # capture_lb_node -- the only consumer that reads this lookup from a memo
  # hit -- never runs. Without this the test cannot observe the difference it
  # exists to pin, whatever the code does.
  *'nc -z'*) echo fail; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$d/bin/kubectl"
  PATH="$d/bin:$PATH" timeout 90 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  # A lookup that answered "none" must read as none wherever it is consumed.
  # capture_lb_node is the only consumer that reads this lookup from a memo
  # hit, and it runs only on the heavy-capture path. Pin that it ran, or stub
  # drift makes both assertions below vacuous without a word.
  grep -q 'ENDPOINT node=node-a' "$d/out/lb-tenant-web.txt"
  if grep -rq 'ovs=<unknown>' "$d/out" 2>/dev/null; then
    echo "a lookup that answered was reported as unanswered after a memo hit:"
    grep -r 'ovs=' "$d/out" 2>/dev/null
    exit 1
  fi
  # And the run must not leak shell diagnostics into the log.
  if grep -q 'unbound variable\|parameter not set' "$d/log"; then
    echo "the run leaked shell diagnostics:"
    grep -n 'unbound variable\|parameter not set' "$d/log" | head -3
    exit 1
  fi
  rm -rf "$d"
}

@test "an instant lookup failure is re-asked rather than cached" {
  # Caching a refusal makes one transient permanent for the run. Only a cutoff
  # is worth not repeating, because repeating that one spends another full
  # bound. The stub refuses the first ovs lookup and answers the rest, so a
  # cached failure would show as a second lookup never being issued.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  cat >"$d/bin/kubectl" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case $a in
    pods) echo 'tenant-test|wedged|10.0.0.1|node-a|False|Running'; exit 0 ;;
    svc) echo 'tenant|web|LoadBalancer|192.0.2.10|80|30080|Cluster'; exit 0 ;;
    endpointslices) echo '10.0.0.1|node-a|tenant-test|wedged|true'; exit 0 ;;
  esac
done
case "$*" in
  *'app=ovs'*)
    echo "$*" >>"$STUB_CALLS"
    echo 'Error from server (Forbidden): pods is forbidden' >&2
    exit 1 ;;
esac
exit 0
STUB
  chmod +x "$d/bin/kubectl"
  STUB_CALLS="$d/calls" PATH="$d/bin:$PATH" timeout 90 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  # More than one ovs lookup means the refusal was not cached.
  n=$(wc -l <"$d/calls" | tr -d ' ')
  if [ "$n" -lt 2 ]; then
    echo "an instant failure was cached instead of re-asked (ovs lookups: $n)"
    cat "$d/calls"
    exit 1
  fi
  rm -rf "$d"
}

@test "the reasons a capture is incomplete ship inside the capture" {
  # A hung apiserver leaves dataplane/ with nothing collected. The lines saying
  # why must be there too, or a reader holding only the uploaded report cannot
  # tell a capture that found nothing from one that never ran -- the contract
  # docs/agents/e2e-testing.md states for the sibling collectors, which this
  # script's notes are modelled on.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  printf '#!/bin/sh\nsleep 300\n' >"$d/bin/kubectl"
  chmod +x "$d/bin/kubectl"
  PATH="$d/bin:$PATH" COZY_DATAPLANE_LIST_TIMEOUT=1 COZY_DATAPLANE_READ_TIMEOUT=1 \
    timeout 90 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  [ -f "$d/out/capture-notes.txt" ]
  grep -q 'cut off' "$d/out/capture-notes.txt"
  grep -q 'whether any pod is affected is unknown' "$d/out/capture-notes.txt"
  rm -rf "$d"
}

@test "dp_cutoff_desc tells a SIGKILL from a deadline and both from no bound" {
  # Pure helper, reached through the sourcing guard like the lb_* ones above.
  # Its three branches carry the difference between "the bound fired", "something
  # killed the read and 137 cannot say which", and "this read had no ceiling at
  # all" -- the last being what an absent `timeout` produces.
  deadline=$(dp_cutoff_desc 124 20 "timeout -k 2 20")
  case "$deadline" in
    *"its own 20s timeout"*) : ;;
    *) echo "124 did not name the deadline: $deadline"; exit 1 ;;
  esac

  killed=$(dp_cutoff_desc 137 20 "timeout -k 2 20")
  case "$killed" in
    *SIGKILL*) : ;;
    *) echo "137 did not name a SIGKILL: $killed"; exit 1 ;;
  esac

  unbounded=$(dp_cutoff_desc 137 20 "")
  case "$unbounded" in
    *unbounded*) : ;;
    *) echo "an empty bound was not described as unbounded: $unbounded"; exit 1 ;;
  esac
}

@test "sourcing the script for its helpers leaves no temp files behind" {
  # Everything above the sourcing guard runs in every unit test that sources
  # this file, so a scratch file created up there is one leaked per test, and
  # the two early exits would strand one on any host without kubectl.
  d=$(mktemp -d)
  ( TMPDIR="$d"; export TMPDIR; E2E_CAPTURE_DATAPLANE_LIB=1 . "$SCRIPT" ) >/dev/null 2>&1
  left=$(ls -1 "$d" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$left" -ne 0 ]; then
    echo "sourcing left $left file(s) behind:"
    ls -1 "$d"
    exit 1
  fi
  rm -rf "$d"
}

@test "an LB whose probe never ran is not recorded as reachable" {
  # Fifth site of the same class, and the last one the bounds made reachable.
  # host_http_probe resolves a cni-server first; a cut-off lookup used to emit
  # no probe outcome at all, which the decision helper read as "nothing failed"
  # and the artifact stamped as reachable -- a verdict about an address the
  # script never touched. At merge base the script never got this far: the
  # unbounded lookup hung until the caller's backstop killed it.
  d=$(mktemp -d)
  mkdir -p "$d/bin"
  cat >"$d/bin/kubectl" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case $a in
    pods) exit 0 ;;
    svc) echo 'tenant|web|LoadBalancer|192.0.2.10|80|30080|Cluster'; exit 0 ;;
    endpointslices) echo '10.0.0.1|node-a|tenant-test|wedged|true'; exit 0 ;;
  esac
done
case "$*" in
  *'app=kube-ovn-cni'*) sleep 300 ;;
esac
exit 0
STUB
  chmod +x "$d/bin/kubectl"
  PATH="$d/bin:$PATH" COZY_DATAPLANE_LIST_TIMEOUT=1 COZY_DATAPLANE_READ_TIMEOUT=1 \
    timeout 90 "$SCRIPT" "$d/out" >"$d/log" 2>&1 || true
  [ -f "$d/out/lb-tenant-web.txt" ]
  # The specific claim, not the bare word: the honest line says "whether the LB
  # is reachable ... is unknown" and contains it too.
  if grep -q -- '-- reachable, skipped' "$d/out/lb-tenant-web.txt"; then
    echo "an LB that was never probed was recorded as reachable:"
    cat "$d/out/lb-tenant-web.txt"
    exit 1
  fi
  grep -q 'is unknown' "$d/out/lb-tenant-web.txt"
  rm -rf "$d"
}

@test "lb_capture_decision keeps failures visible when one probe could not run" {
  # An unrun probe adds no reason to doubt the ones that failed, so the mix must
  # not read as reachable. Collapsing it toward skip is what stamps the artifact
  # with a reachability verdict for an address whose probes failed.
  [ "$(printf 'unknown\nfail\nfail\n' | lb_capture_decision)" = "capture" ]
}

@test "lb_capture_decision returns unknown only when nothing could be attempted" {
  [ "$(printf 'unknown\nunknown\nunknown\n' | lb_capture_decision)" = "unknown" ]
  # A success still wins: the address answered, whatever else could not be tried.
  [ "$(printf 'unknown\nok\n' | lb_capture_decision)" = "skip" ]
}
