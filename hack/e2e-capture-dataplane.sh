#!/bin/sh
# e2e-capture-dataplane.sh - capture host->pod data-plane state for NotReady pods.
#
# DIAGNOSTIC ONLY. This script collects extra evidence on an already-failed
# test; it never mutates the cluster and never changes the test's pass/fail
# outcome. Two callers invoke it, each from its own on-failure path and each
# AFTER the crust-gather snapshot: the cozytest.sh EXIT trap and the Chainsaw
# global catch in hack/e2e-chainsaw/.chainsaw.yaml. Both write into the same
# snapshot dir so the output lands in the uploaded cozyreport artifact, and both
# wrap this script in a wall-clock backstop -- but not the same one (600s and
# 300s respectively), so a change sized against one caller can still overrun the
# other. The MAX_LBS note below carries that arithmetic.
#
# Why this exists: a recurrent install failure is a CNI host->local-pod
# data-plane transient -- kubelet on a node reaches a *local* pod's
# readiness/startup probe with "connection refused" for several minutes while
# overlay (pod->pod) traffic works, then it self-heals. This is rooted in the
# cozystack cilium+kube-ovn chaining config (forced enable-host-legacy-routing,
# CNI InstallEndpointRoute:false -> host->local-pod routing is delegated to
# kube-ovn/ovn0). The standard crust-gather snapshot captures Kubernetes object
# state but NOT the L3 forwarding state on the node, so the mechanism cannot be
# root-caused after the fact. This collects exactly that state from the pod's
# node so the next recurrence is dispositive.
#
# What it captures, per affected pod (NotReady and scheduled; podIP may still
# be empty while CNI endpoint allocation is the thing that is stuck):
#   - cilium-agent on the node:  cilium-dbg endpoint list; bpf ct entries for
#     the podIP; a short bounded `cilium-dbg monitor --type drop`; hubble
#     dropped-verdict observations (if the hubble CLI is present in the agent).
#     NOTE: under enable-host-legacy-routing the host->local-pod path traverses
#     the KERNEL netfilter stack, not cilium BPF, so the cilium CT/monitor view
#     is complementary -- the authoritative conntrack table for this path is the
#     kernel one captured below. Both are kept: cilium's view still covers
#     pod->pod and confirms the path is NOT in BPF, which is itself evidence.
#   - host netns on the node (via the kube-ovn cni-server, which is
#     hostNetwork+NET_ADMIN): `ip route get <podIP>`, `ip neigh`, `ip rule`,
#     `ip addr show ovn0`, and the KERNEL conntrack entries for the podIP
#     (`conntrack -L`, falling back to /proc/net/nf_conntrack). These reveal a
#     kernel-path misforward / missing route / wrong rule / unresolved neighbor
#     -- the actual mechanism behind host->local-pod "connection refused" on the
#     legacy-routing path (the crux of the transient).
#   - OVS/OVN on the node: `ovs-ofctl dump-flows br-int`, and the OVN
#     Port_Binding / Logical_Switch_Port for the pod (LSP name = <pod>.<ns> in
#     kube-ovn) plus a bounded `ovn-sbctl lflow-list`.
#   - OVN flow-programming timing on the node (ovs-ovn pod, app=ovs -- its
#     openvswitch container also runs ovn-controller): the tail of
#     /var/log/ovn/ovn-controller.log plus a grep for the decisive lines
#     (physical_flow_output, if_status_mgr, "took <N>ms", recompute,
#     "Unreasonably long ... poll interval"); the per-interface ovn-installed
#     flag + ovn-installed-ts on the pod's OVS interface; and the ovs-ovn
#     container's cgroup cpu.stat (nr_throttled / throttled_usec). Why: the
#     host->local-pod transient is consistent with OVN incremental-processing
#     lag -- ovn-installed=true (the kubelet/CNI "port ready" barrier) is set by
#     if_status_mgr BEFORE physical_flow_output installs the LSP's local-delivery
#     OpenFlow under burst, aggravated when ovn-controller is CPU-throttled (it
#     shares the ovs-ovn CPU limit with vswitchd). A `physical_flow_output ...
#     took <N>ms` line spanning the failure window, an ovn-installed-ts that
#     predates that flow, and non-zero cpu.stat throttling together make a
#     recurrence dispositive.
#
# What it ALSO captures (added section) -- an UNREACHABLE LoadBalancer datapath:
#   The NotReady-pod trigger above misses a second, equally-recurrent flake. A
#   tenant `Service type=LoadBalancer` IP goes unreachable while its backend
#   pod/VMI stays Ready+Running -- so there is NO NotReady pod, the capture above
#   no-ops, and the host->cross-node->bridged-worker-VMI->tenant-nodePort
#   datapath (the suspected failing path) is never characterised. This section
#   closes that gap. It is gated by a LIVE reachability probe so it only does the
#   heavy capture for an LB that is actually broken; reachable LBs are enumerated
#   and explicitly recorded as "reachable, skipped".
#     - Enumerate every Service type=LoadBalancer that has a status ingress IP.
#       For each, derive: the EndpointSlice backend (endpoint IP + node +
#       targetPort), the Service nodePort + externalTrafficPolicy, and the
#       ANNOUNCER node from the MetalLB speaker logs (the hostNetwork speaker is
#       the L2 owner; the node of its most recent serviceAnnounced for the IP is
#       the announcer).
#     - Probe the LB IP:port a few times from a host netns (the kube-ovn
#       cni-server, so the probe traverses the same host-sourced datapath the
#       flake breaks). Only an LB whose every probe FAILS gets the heavy capture
#       below, and that same probe is the traffic the tcpdumps observe.
#     - For a FAILING LB, on BOTH the announcer node and the endpoint node
#       (reusing pod_on_node), labelled by node + role (ANNOUNCER vs ENDPOINT):
#         * `cilium-dbg bpf lb list` grepped for the LB IP + nodePort -- did the
#           HOST cilium program the LB->backend translation? This is the first
#           fork: host-cilium-not-programming vs kube-ovn-delivery-failure.
#         * kernel `conntrack -L -d <LB IP>` + `ip neigh` (LB IP, endpoint IP)
#           via the cni-server host netns.
#         * `ovs-ofctl dump-flows br-int` filtered to the nodePort / endpoint IP.
#         * a bounded `tcpdump` on the announcer node's geneve tunnel iface and
#           the endpoint node's backend OVS/tap iface, run WHILE the probe is
#           replayed, to show whether the packet crosses announcer->endpoint and
#           reaches the backend's host-side interface.
#         * the ovn-controller.log decisive lines for the window.
#     In-guest capture INSIDE the worker VMI (tenant `cilium-dbg bpf lb list` /
#     `tcpdump eth0`) is the one hop this cannot reach from the host; it is left
#     as a documented stretch at the call site (it needs a tenant
#     kubeconfig/virtctl that neither caller of this diagnostic has). The host-side
#     ANNOUNCER/ENDPOINT split is the deliverable and already localises the
#     failing hop to host-cilium vs kube-ovn delivery.
#
# Robustness contract (matches docs/agents/e2e-testing.md): pure diagnostics,
# no retries, no behavior change, no traps. Every live capture is time-boxed,
# and no command can fail or stall the job: most are `|| true`, and the few
# whose status is read take it into a variable and use it only to say why a
# read produced nothing. A wall-clock backstop wraps the whole run at each call
# site. It no-ops cleanly when there are no affected pods.
#
# Why a read produced nothing is written to capture-notes.txt beside the
# capture, not only to the job log: the reader who has the uploaded report and
# not the run is the one who cannot otherwise tell a capture that found nothing
# from one that never ran.
set -u

# --------------------------------------------------------------------------- #
# Pure, side-effect-free helpers for the LoadBalancer-datapath section below.  #
# Each takes text on stdin / in args and emits text -- no kubectl, no globals  #
# -- so hack/capture-dataplane.bats can source this file (with                 #
# E2E_CAPTURE_DATAPLANE_LIB set, see the guard below) and unit-test the        #
# enumeration parsing, announcer-node detection, and capture-or-skip decision  #
# against mock input without a cluster. Keep them above the guard and free of  #
# any runtime state.                                                           #
# --------------------------------------------------------------------------- #

# lb_filter_services: stdin = `ns|name|type|lbip|port|nodePort|extPolicy` rows
# (one Service per line, as emitted by the kubectl jsonpath in main). Emits only
# the rows that are type=LoadBalancer AND carry a status ingress IP -- i.e. the
# Services that actually have an external datapath to characterise.
lb_filter_services() {
  awk -F'|' '$3 == "LoadBalancer" && $4 != "" { print }'
}

# lb_first_ready_endpoint: stdin = `ip|node|targetNs|targetName|ready` rows (one
# EndpointSlice endpoint per line). Emits `ip|node|targetNs|targetName` for the
# first endpoint that has an address and is not explicitly NotReady, then stops.
# A blank `ready` (slice without conditions) counts as ready; only "false" is
# excluded. This is the backend the LB IP is supposed to reach.
lb_first_ready_endpoint() {
  awk -F'|' '$1 != "" && $5 != "false" { print $1 "|" $2 "|" $3 "|" $4; exit }'
}

# lb_announcer_node <lbip>: stdin = MetalLB speaker logs, each line prefixed with
# the emitting speaker pod's node and a TAB (`<node>\t<logline>`). The speaker is
# hostNetwork and only the elected L2 owner currently announces the IP. Reports a
# node ONLY IF that node's LAST own IP-event for this exact IP is an announce: per
# node we track its most recent announce/withdraw line for the IP, so a node that
# announced then withdrew (last event = withdraw) is excluded and a node that is
# still announcing (last event = announce) qualifies. This is robust to the
# per-pod (not globally time-sorted) concat order of the speaker logs and to L2
# failover. If more than one node still qualifies (should not happen for an L2
# announce), the one whose last announce appears latest in the input wins.
# The IP is matched as a whole token (not a substring), so a query for
# `192.0.2.5` does NOT match a `192.0.2.50` line. Emits the announcer node, or
# nothing when no node currently announces the IP.
lb_announcer_node() {
  awk -F'\t' -v ip="$1" '
    BEGIN {
      # Match the IP as a maximal IP-literal token: not flanked by another
      # IP char (digit / dot / hex / colon), so `192.0.2.5` != `192.0.2.50`.
      # `[.]` escapes each dot portably (no gsub-replacement backslash games).
      ipre = ip
      gsub(/\./, "[.]", ipre)
      re = "(^|[^0-9A-Fa-f:.])" ipre "([^0-9A-Fa-f:.]|$)"
    }
    $0 ~ re {
      if      ($0 ~ /[Ww]ithdraw/) ev = "withdraw"
      else if ($0 ~ /[Aa]nnounc/)  ev = "announce"
      else                         next
      last_ev[$1]   = ev
      last_line[$1] = NR
    }
    END {
      best = ""; bestline = -1
      for (n in last_ev) {
        if (last_ev[n] == "announce" && last_line[n] > bestline) {
          bestline = last_line[n]
          best = n
        }
      }
      if (best != "") print best
    }'
}

# lb_capture_decision: stdin = one probe outcome token per line ("ok" / "fail" /
# "unknown", the last meaning the probe could not be run at all).
# Emits the gate decision for the heavy per-node capture:
#   - "capture" when at least one probe ran, none succeeded, and at least one
#     genuinely failed (the LB IP is unreachable -- the symptom we want
#     characterised). A failure alongside an unrun probe still counts: the
#     failures are evidence, and the unrun one adds no reason to doubt them;
#   - "skip" when any probe succeeded (LB reachable) OR no probe ran at all (no
#     HTTP/TCP client in the host netns -> cannot conclude unreachable, so only
#     the cheap metadata is kept, never the heavy capture);
#   - "unknown" when every outcome is unknown, i.e. nothing was ever attempted
#     because the lookups behind the probe did not answer. Collapsing that into
#     either of the other two would put a verdict about the address into the
#     artifact without a single probe behind it.
lb_capture_decision() {
  awk '
    { if ($0 == "") next; n++; if ($0 == "ok") ok++; if ($0 == "unknown") unk++ }
    END {
      if (n == 0) { print "skip"; exit }
      # Only a wholly unknown set is unknown. One unrun probe beside real
      # failures must not erase them: the failures are the evidence this
      # capture exists to characterise, and merge-base behaviour for that mix
      # was to capture.
      if (unk > 0 && unk == n) { print "unknown"; exit }
      if (ok > 0) { print "skip"; exit }
      print "capture"
    }'
}

# lb_budget_ok <captured-so-far> <max>: gate for the heavy per-LB capture budget.
# Emits "yes" while fewer than <max> LBs have been CAPTURED, "no" once the cap is
# reached. The cap bounds LBs actually captured -- the caller increments only on
# the capture branch, so reachable/skipped LBs never consume it and a broken LB
# enumerated after many reachable ones is still characterised. The cap bounds
# WORK, not wall-clock: at >=2 unreachable LBs (each heavy capture takes tens of
# seconds) the real wall-clock bound is the outer `timeout -k 30 <n>` backstop at
# the call site, not this cap. That budget differs per caller -- the cozytest.sh
# EXIT trap runs with no containing operation and allows 600s, while the Chainsaw
# global catch shares an op envelope with the crust-gather snapshot and allows
# 300s -- so do not hard-code either number here.
lb_budget_ok() {
  if [ "$1" -lt "$2" ]; then echo yes; else echo no; fi
}

# pod_filter_affected: stdin =
# `namespace|name|podIP|nodeName|ready|phase` rows. Keep scheduled, non-terminal
# pods whose Ready condition is not True. podIP is deliberately NOT a gate: the
# cilium endpointManager leak this collector diagnoses can strand a pod before
# an IP is assigned, and the node-global Cilium/OVN state plus pod events remain
# useful in that state. IP-specific commands are gated later at their call sites.
pod_filter_affected() {
  awk -F'|' '$4 != "" && $5 != "True" && $6 != "Succeeded" && $6 != "Failed"'
}

# How a cutoff should be described, mirroring prevlog_cutoff_desc in the sibling
# script: 137 cannot tell its own kill grace apart from something else killing
# the read, and an empty bound means the read was never bounded here at all.
dp_cutoff_desc() {
  if [ -z "$3" ]; then
    printf '%s' "a signal from outside this script, which ran this read unbounded"
  elif [ "${1:-}" = "137" ]; then
    printf '%s' "a SIGKILL -- the kill grace of its own ${2}s timeout, or something else killing the read, which 137 does not tell apart"
  else
    printf '%s' "its own ${2}s timeout"
  fi
}


# dp_read_outcome <rc> <seconds> <bound> [errfile] -> phrase describing why a
# read produced nothing.
#
# 124 and 137 are the only statuses a bound produces, so they are the only ones
# allowed to name the timeout. Everything else is kubectl answering -- a refused
# connection, an RBAC denial, a kind the cluster does not serve -- and calling
# that a cutoff would put a cause in the artifact that was never observed. The
# sibling capture gates every one of its notes the same way, and this script's
# notes claim to follow it.
dp_read_outcome() {
  if [ "${1:-}" = "124" ] || [ "${1:-}" = "137" ]; then
    printf '%s' "was cut off by $(dp_cutoff_desc "$1" "$2" "$3")"
  elif [ -n "${4:-}" ] && [ -s "${4:-}" ]; then
    printf 'failed: kubectl exited %s: %s' "$1" "$(tr '\n\r' '  ' <"$4" | cut -c1-300 | sed 's/[[:space:]]*$//')"
  else
    printf 'failed: kubectl exited %s' "$1"
  fi
}

# Kept above the sourcing guard with the other pure helpers, per the note at
# the top of this section: their branches carry the difference between a
# deadline, a kill and a read that had no ceiling, and the unit suite asserts
# them directly rather than inferring them from a capture.

# Sourcing guard: hack/capture-dataplane.bats sets E2E_CAPTURE_DATAPLANE_LIB and
# sources this file purely to reach the helpers above; return before touching $1
# or running any capture so the unit test never needs a cluster. Neither
# executing caller sets it -- not the cozytest.sh EXIT trap, not the Chainsaw
# global catch -- so the guard is a no-op for both.
if [ -n "${E2E_CAPTURE_DATAPLANE_LIB:-}" ]; then
  return 0 2>/dev/null
fi

OUT="${1:?Usage: e2e-capture-dataplane.sh <output-dir>}"

CILIUM_NS="${COZY_CILIUM_NS:-cozy-cilium}"
KUBEOVN_NS="${COZY_KUBEOVN_NS:-cozy-kubeovn}"
# Cap how many pods we inspect so a fully-wedged cluster cannot explode the
# runtime; the per-command timeouts and the call-site wall-clock wrapper are the
# other two bounds. Node-global captures are deduped per node, so the effective
# work is closer to (#affected-nodes) than (#affected-pods).
MAX_PODS="${COZY_DATAPLANE_MAX_PODS:-12}"

# LoadBalancer-datapath section tunables (see the header block and the
# capture_lb_datapath function near the end of this file). The speaker selector
# and geneve iface match the cozystack metallb/cilium+kube-ovn defaults but stay
# overridable so a renamed component cannot silently blank the capture.
METALLB_NS="${COZY_METALLB_NS:-cozy-metallb}"
SPEAKER_SELECTOR="${COZY_METALLB_SPEAKER_SELECTOR:-app.kubernetes.io/component=speaker}"
GENEVE_IFACE="${COZY_GENEVE_IFACE:-genev_sys_6081}"
# Cap how many UNREACHABLE LBs get the heavy datapath capture; reachable/skipped
# LBs never count toward it (see the captured-budget gate in capture_lb_datapath).
# This bounds WORK, not wall-clock: at >=2 unreachable LBs the real wall-clock
# bound is the outer `timeout -k 30 <n>` backstop at the call site (truncate +
# hard-kill), since each heavy capture itself takes tens of seconds. That budget
# is per-caller (600s from the cozytest.sh EXIT trap, 300s from the Chainsaw
# global catch, which shares an op envelope with the snapshot leg).
MAX_LBS="${COZY_DATAPLANE_MAX_LBS:-6}"

# Per-read wall-clock bounds for the plain `kubectl get` reads below. Named once
# so a message reporting a cutoff cannot quote a number the read never used, and
# overridable so a test does not have to wait out the real ones. The list bound
# is larger because that call asks about every namespace at once, where the
# others ask about one object.
#
# These bound a single READ, not the script: the sum of every bound here is far
# past any caller's envelope, and deliberately so, because the caps above bound
# work while the outer `timeout -k` bounds wall clock (see the note above). What
# a per-read bound buys is forward progress -- one hung apiserver call can no
# longer consume the whole envelope before anything is written.
DP_READ_TIMEOUT="${COZY_DATAPLANE_READ_TIMEOUT:-20}"
DP_LIST_TIMEOUT="${COZY_DATAPLANE_LIST_TIMEOUT:-28}"
DP_READ_GRACE=2

# Resolved once. Empty when `timeout` is absent: the reads then run unbounded
# rather than every call exiting 127 with its output swallowed, which would
# report that kubectl failed when kubectl never ran. The seven reads that carry
# a note say which of the two happened; the two EndpointSlice reads inside
# capture_lb_datapath still send stderr to /dev/null and report nothing either
# way.
if command -v timeout >/dev/null 2>&1; then
  DP_BOUND="timeout -k $DP_READ_GRACE $DP_READ_TIMEOUT"
  DP_LIST_BOUND="timeout -k $DP_READ_GRACE $DP_LIST_TIMEOUT"
else
  DP_BOUND=""
  DP_LIST_BOUND=""
fi

command -v kubectl >/dev/null 2>&1 || exit 0
mkdir -p "$OUT" 2>/dev/null || exit 0
# Every note below explains why this capture is smaller than the cluster, so it
# ships beside the capture rather than only in the job log: a reader who has the
# uploaded report and not the run cannot otherwise tell a capture that found
# nothing from one that never ran. The sibling collector and the report writer
# both hold this contract, and docs/agents/e2e-testing.md states it for them.
#
# Appended, not truncated, with a separator: a caller may aim two runs at one
# directory, and the earlier run's reasons are as load-bearing as the later
# one's.
NOTES="$OUT/capture-notes.txt"

# Created here rather than beside the helpers above, and the position is the
# point: everything before the sourcing guard runs in every unit test that
# sources this file, so a temp file made up there is one leaked per test, and
# the two early exits would leave one behind on every host without kubectl.
# Below the guard and below those exits, the cleanup at the end is genuinely
# the only path that can be reached once this exists.
#
# Empty if mktemp fails; the notes then omit kubectl's message rather than
# inventing one.
DP_ERR=$(mktemp "${TMPDIR:-/tmp}/dataplane-read.XXXXXX" 2>/dev/null) || DP_ERR=""
if [ -s "$NOTES" ]; then
  printf -- '--- new capture run ---\n' >> "$NOTES" 2>/dev/null || true
fi

# printf, not echo: under /bin/sh (dash on the CI image) echo expands backslash
# escapes, and this logger now carries kubectl's own stderr. A message holding a
# literal \n could then break the note in two and print a second
# "[capture-dataplane] ..." line that reads as this script's own verdict. No
# malice needed -- the jsonpath in these reads contains {"\n"}, and kubectl
# quotes the expression back when it fails to parse it. The tr in
# dp_read_outcome flattens the message on the way in; echo would undo that here,
# on the way out.
log() {
  printf '%s\n' "[capture-dataplane] $*"
  printf '%s\n' "[capture-dataplane] $*" >> "$NOTES" 2>/dev/null || true
}


# Affected = scheduled (has nodeName), Ready!=True, and not already terminal.
# A podIP is intentionally optional: a CNI endpoint leak can strand the pod
# before allocation. Running pods with an IP cover the host->pod probe failure;
# Pending pods without one cover the endpoint-allocation failure. Succeeded/
# Failed pods (completed Jobs, hook pods) are Ready!=True too but are not either
# symptom, so they are excluded to keep the MAX_PODS budget on actual wedges.
# jsonpath keeps this dependency-free (no jq / go-template reassignment).
# shellcheck disable=SC2086  # empty DP_LIST_BOUND must vanish, not become ""
_pods_raw=$($DP_LIST_BOUND kubectl get pods -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.status.podIP}{"|"}{.spec.nodeName}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"|"}{.status.phase}{"\n"}{end}' \
  2>"${DP_ERR:-/dev/null}")
_pods_rc=$?
if [ "$_pods_rc" -ne 0 ]; then
  log "listing pods $(dp_read_outcome "$_pods_rc" "$DP_LIST_TIMEOUT" "$DP_LIST_BOUND" "$DP_ERR"); whatever it did not name is missing from the capture below, which is not the same as nothing being affected"
fi
affected=$(printf '%s' "$_pods_raw" | pod_filter_affected)

# Set even when the pod path is empty; the per-pod capture references it, while
# the independent LoadBalancer path below does not.
central=""

# pod_on_node <ns> <label> <node> -> first matching pod name (empty if none).
pod_on_node() {
  _pon_key="$1/$2/$3"
  if _pon_hit=$(pod_memo_get "$_pon_key"); then
    printf '%s' "${_pon_hit%%	*}"
    return "${_pon_hit#*	}"
  fi
  # shellcheck disable=SC2086  # empty DP_BOUND must vanish, not become ""
  # items[*], not items[0]: client-go's evalArray has no allowMissingKeys escape
  # (evalField does), so indexing [0] into an empty list is a hard error and
  # kubectl exits 1. "No such pod on this node" is the ordinary answer here --
  # a node without a cilium-agent is exactly what this capture is called for --
  # and with a note attached to a non-zero status that answer would be reported
  # as a failed read. [*] yields nothing and exits 0, so a non-zero status again
  # means something actually went wrong.
  _pon=$($DP_BOUND kubectl get pod -n "$1" -l "$2" --field-selector "spec.nodeName=$3" \
    -o jsonpath='{.items[*].metadata.name}' 2>"${DP_ERR:-/dev/null}")
  _pon_rc=$?
  # The note goes to stderr because this function's stdout is captured by its
  # callers, so a log line on stdout would be read as part of the pod name.
  if [ "$_pon_rc" -ne 0 ]; then
    # No consequence named: this helper serves five call sites with three
    # different ones -- a node-global capture skipped, an LB probe not run, an
    # announcer left to the fallback -- so any clause here is wrong for someone.
    # The status goes back with the value instead, and the two callers that
    # write an absence into the artifact use it to say "unknown" rather than
    # "none"; the ones that only skip have nothing to record.
    log "looking up the pod matching $2 on node $3 $(dp_read_outcome "$_pon_rc" "$DP_READ_TIMEOUT" "$DP_BOUND" "$DP_ERR")" >&2
  fi
  # [*] can name several pods; the callers want one. The status goes back to the
  # caller as well: an empty answer means "no such pod" only when the read
  # actually answered, and the callers write that difference into the artifact.
  case "$_pon_rc" in
    0 | 124 | 137) pod_memo_put "$_pon_key" "${_pon%% *}" "$([ "$_pon_rc" -ne 0 ] && echo 1 || echo 0)" ;;
  esac
  printf '%s' "${_pon%% *}"
  [ "$_pon_rc" -eq 0 ]
}

# Per-node captures are node-global (every pod on a node shares one cilium-agent
# / ovs / cni-server), so run them once per node and reuse across that node's
# pods. POSIX-sh membership test over a space-delimited string.
_SEEN_NODES=" "
node_seen() { case "$_SEEN_NODES" in *" $1 "*) return 0 ;; esac; return 1; }
mark_node() { _SEEN_NODES="$_SEEN_NODES$1 "; }

# Memo for pod_on_node. The same (namespace, label, node) is asked up to three
# times per affected pod across the sections below, and each repeat now costs
# its own timeout against an apiserver that hangs: the bounds turned a free
# repetition into one that spends the caller's envelope on re-asking rather than
# on more pods. An empty answer is memoised too, since "there is no
# cilium-agent on this node" is exactly the lookup worth not repeating.
#
# A read that failed is stored only when a bound cut it off. An instant failure
# -- refused, denied -- costs nothing to ask again, and caching it would make
# one transient permanent for the run: the LB section would take the hit, report
# the component unknown, and skip the capture this file's header calls the first
# fork of an LB diagnosis. A cutoff is the opposite, since asking again spends
# another full bound, which is the budget this memo exists to protect.
#
# Unlike the node memo above, which is a space-delimited string matched with a
# case glob, this one is a tab-separated file compared field by field, so the
# key needs no quoting and the '=' inside a label selector is ordinary payload.
# The invariant it does rest on is that none of namespace, label selector or
# node name may contain a tab, which Kubernetes object names and label
# selectors cannot.
# Backed by a file rather than a variable on purpose: the walk over affected
# pods runs on the right-hand side of a pipeline, which is a subshell, so a
# variable memo would be discarded at the end of it and the same lookups would
# be paid for again in the sections that follow. Empty when mktemp fails, which
# only costs the memo.
_POD_MEMO=$(mktemp "${TMPDIR:-/tmp}/dataplane-podmemo.XXXXXX" 2>/dev/null) || _POD_MEMO=""
# The stored row carries the read's status beside its value. A hit that dropped
# it would hand a later caller an empty answer with no way to tell "there is no
# such pod" from "the read never said", which is the distinction the callers
# below are built on.
#
# The status leaves through stdout, packed with the value, because every caller
# reads this through a command substitution and a variable set in there dies
# with the subshell -- the same property that makes the memo itself a file.
pod_memo_get() {
  [ -n "$_POD_MEMO" ] || return 1
  awk -F'\t' -v k="$1" '$1 == k { printf "%s\t%s", $2, $3; found = 1; exit } END { exit !found }' \
    "$_POD_MEMO" 2>/dev/null
}
pod_memo_put() {
  [ -n "$_POD_MEMO" ] || return 0
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$_POD_MEMO" 2>/dev/null || true
}

capture_node() {
  node=$1
  node_seen "$node" && return 0
  mark_node "$node"
  nf="$OUT/node-$node.txt"

  agent=$(pod_on_node "$CILIUM_NS" k8s-app=cilium "$node"); _agent_ok=$?
  ovs=$(pod_on_node "$KUBEOVN_NS" app=ovs "$node"); _ovs_ok=$?
  {
    echo "################################################################"
    _agent_shown=${agent:-$([ "$_agent_ok" -eq 0 ] && echo '<none>' || echo '<unknown>')}
    _ovs_shown=${ovs:-$([ "$_ovs_ok" -eq 0 ] && echo '<none>' || echo '<unknown>')}
    echo "# NODE $node  (cilium-agent=$_agent_shown ovs=$_ovs_shown)"
    echo "################################################################"

    if [ -n "$agent" ]; then
      echo
      echo "=== cilium-dbg endpoint list ==="
      timeout 25 kubectl exec -n "$CILIUM_NS" "$agent" -c cilium-agent -- \
        cilium-dbg endpoint list 2>&1 || true

      echo
      echo "=== cilium-dbg monitor --type drop (bounded ~8s) ==="
      # Two nested bounds: an inner `timeout 8` so the capture self-terminates
      # if the agent ships coreutils, and an outer `timeout 12` on the exec as
      # the hard backstop if it does not. Either way it cannot hang.
      timeout 12 kubectl exec -n "$CILIUM_NS" "$agent" -c cilium-agent -- \
        sh -c 'timeout 8 cilium-dbg monitor --type drop 2>&1 || true' 2>&1 || true

      echo
      echo "=== hubble observe --verdict DROPPED --last 200 (if hubble present) ==="
      timeout 25 kubectl exec -n "$CILIUM_NS" "$agent" -c cilium-agent -- \
        sh -c 'command -v hubble >/dev/null 2>&1 && hubble observe --verdict DROPPED --last 200 2>&1 || echo "hubble CLI not present in agent"' 2>&1 || true
    else
      echo
      if [ "$_agent_ok" -eq 0 ]; then
        echo "(no cilium-agent pod found on node $node)"
      else
        echo "(could not determine whether a cilium-agent runs on node $node -- the lookup did not answer)"
      fi
    fi

    if [ -n "$ovs" ]; then
      echo
      echo "=== ovs-ofctl dump-flows br-int ==="
      timeout 25 kubectl exec -n "$KUBEOVN_NS" "$ovs" -c openvswitch -- \
        ovs-ofctl dump-flows br-int 2>&1 || true

      echo
      echo "=== ovn-controller.log decisive lines (flow-programming / I-P timing) ==="
      # ovn-controller runs inside this ovs-ovn (app=ovs) pod's openvswitch
      # container and logs to /var/log/ovn/ovn-controller.log. Grep the lines
      # that pin OVN incremental-processing lag: physical_flow_output (installs
      # the LSP local-delivery OpenFlow), if_status_mgr (sets ovn-installed --
      # the CNI "port ready" barrier), and "took <N>ms" / recompute /
      # "Unreasonably long ... poll interval" (ovn-controller stalls). A
      # physical_flow_output "took <N>ms" spanning the failure window is proof.
      timeout 25 kubectl exec -n "$KUBEOVN_NS" "$ovs" -c openvswitch -- \
        sh -c 'grep -E "physical_flow_output|if_status_mgr|took [0-9]+ ?ms|recompute|Unreasonably long" /var/log/ovn/ovn-controller.log 2>/dev/null | tail -n 400 || echo "no matching lines in /var/log/ovn/ovn-controller.log"' 2>&1 || true

      echo
      echo "=== ovn-controller.log tail (bounded) ==="
      timeout 20 kubectl exec -n "$KUBEOVN_NS" "$ovs" -c openvswitch -- \
        sh -c 'tail -n 2000 /var/log/ovn/ovn-controller.log 2>/dev/null || echo "no /var/log/ovn/ovn-controller.log"' 2>&1 || true

      echo
      echo "=== ovs-ovn cgroup cpu.stat (ovn-controller/vswitchd CPU throttling) ==="
      # ovs-ovn caps CPU (shared between ovn-controller and vswitchd); non-zero
      # nr_throttled / throttled_usec means ovn-controller was CPU-starved, which
      # aggravates the flow-programming lag above. cgroup v2 path first, v1
      # fallback.
      timeout 15 kubectl exec -n "$KUBEOVN_NS" "$ovs" -c openvswitch -- \
        sh -c 'cat /sys/fs/cgroup/cpu.stat 2>/dev/null || cat /sys/fs/cgroup/cpu/cpu.stat 2>/dev/null || echo "no cpu.stat at /sys/fs/cgroup/cpu.stat (v2) or /sys/fs/cgroup/cpu/cpu.stat (v1)"' 2>&1 || true
    else
      echo
      if [ "$_ovs_ok" -eq 0 ]; then
        echo "(no ovs pod found on node $node)"
      else
        echo "(could not determine whether an ovs pod runs on node $node -- the lookup did not answer)"
      fi
    fi

    cni=$(pod_on_node "$KUBEOVN_NS" app=kube-ovn-cni "$node"); _cni_ok=$?
    if [ -n "$cni" ]; then
      echo
      echo "=== host netns: ip neigh (via kube-ovn cni-server, hostNetwork) ==="
      timeout 15 kubectl exec -n "$KUBEOVN_NS" "$cni" -c cni-server -- \
        ip neigh 2>&1 || true

      echo
      echo "=== host netns: ip rule ==="
      timeout 15 kubectl exec -n "$KUBEOVN_NS" "$cni" -c cni-server -- \
        ip rule 2>&1 || true

      echo
      echo "=== host netns: ip addr show ovn0 ==="
      timeout 15 kubectl exec -n "$KUBEOVN_NS" "$cni" -c cni-server -- \
        ip addr show ovn0 2>&1 || true
    else
      echo
      if [ "$_cni_ok" -eq 0 ]; then
        echo "(no kube-ovn-cni pod found on node $node -- host netns capture skipped)"
      else
        echo "(could not determine whether a kube-ovn-cni pod runs on node $node -- the lookup did not answer; host netns capture skipped)"
      fi
    fi
  } >> "$nf" 2>&1 || true
}

if [ -z "$affected" ] && [ "$_pods_rc" -ne 0 ]; then
  # Says what is unknown rather than what the read did. The list can answer in
  # part and name only healthy pods, which lands here too, so a line asserting
  # that it never answered would be wrong in exactly the case the note above
  # already describes. The other two branches of this kind are worded the same
  # way for the same reason.
  log "whether any pod is affected is unknown -- checking LoadBalancers independently"
elif [ -z "$affected" ]; then
  log "no scheduled NotReady pods -- skipping host->pod capture; checking LoadBalancers independently"
else
  ncount=$(printf '%s\n' "$affected" | wc -l | tr -d ' ')
  log "capturing host->pod data-plane for up to $MAX_PODS of $ncount affected pod(s) -> $OUT"

  # OVN southbound logical-flow dump is cluster-global, so capture it once
  # rather than per pod. ovn-central is a Deployment (not per-node); any replica
  # answers. --no-leader-only lets a read land on a raft follower instead of
  # erroring.
  # shellcheck disable=SC2086  # empty DP_BOUND must vanish, not become ""
  # items[*] for the same reason as pod_on_node: an absent ovn-central is a
  # cluster without kube-ovn, not a read that failed.
  central=$($DP_BOUND kubectl get pod -n "$KUBEOVN_NS" -l app=ovn-central \
    -o jsonpath='{.items[*].metadata.name}' 2>"${DP_ERR:-/dev/null}")
  _central_rc=$?
  central=${central%% *}
  if [ "$_central_rc" -ne 0 ]; then
    # No consequence named here: the lookup can fail after naming a replica, in
    # which case the dump below runs on what it named. The branch that actually
    # skips says so itself.
    log "looking up an ovn-central replica $(dp_read_outcome "$_central_rc" "$DP_READ_TIMEOUT" "$DP_BOUND" "$DP_ERR")"
  fi
  if [ -n "$central" ]; then
    {
      echo "=== ovn-sbctl lflow-list (cluster-global, pod=$central) ==="
      timeout 30 kubectl exec -n "$KUBEOVN_NS" "$central" -c ovn-central -- \
        ovn-sbctl --no-leader-only lflow-list 2>&1 || true
    } > "$OUT/ovn-lflows.txt" 2>&1 || true
  elif [ "$_central_rc" -ne 0 ]; then
    # Same distinction the pod list makes above: a lookup that never answered is
    # not a cluster without ovn-central. Saying otherwise here would contradict
    # the note printed a few lines up.
    log "whether $KUBEOVN_NS runs ovn-central is unknown -- skipping OVN logical-flow dump"
  else
    log "no ovn-central pod in $KUBEOVN_NS -- skipping OVN logical-flow dump"
  fi

  i=0
  printf '%s\n' "$affected" | {
  while IFS='|' read -r ns pod podip node _ready _phase; do
    [ -n "$ns" ] && [ -n "$pod" ] && [ -n "$node" ] || continue
    i=$((i + 1))
    if [ "$i" -gt "$MAX_PODS" ]; then
      log "reached MAX_PODS=$MAX_PODS cap; $((ncount - MAX_PODS)) more affected pod(s) NOT captured"
      break
    fi

    # Node-global state (cilium endpoints, monitor, hubble, ovs flows, ip neigh,
    # ip rule, ovn0 addr) -- captured once per node.
    capture_node "$node"

    # Pod-specific state.
    pf="$OUT/pod-$ns-$pod.txt"
    agent=$(pod_on_node "$CILIUM_NS" k8s-app=cilium "$node")
    ovs=$(pod_on_node "$KUBEOVN_NS" app=ovs "$node")
    {
      echo "################################################################"
      echo "# POD $ns/$pod  podIP=${podip:-<none>}  node=$node  (Ready=$_ready)"
      echo "# node-global captures are in node-$node.txt"
      echo "################################################################"

      echo
      echo "=== pod Ready conditions + recent probe events ==="
      # shellcheck disable=SC2086  # empty DP_BOUND must vanish, not become ""
      $DP_BOUND kubectl get pod -n "$ns" "$pod" \
        -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason}: {.message}{"\n"}{end}' 2>&1 \
        || echo "(reading this pod's Ready conditions $(dp_read_outcome "$?" "$DP_READ_TIMEOUT" "$DP_BOUND"))"
      # shellcheck disable=SC2086  # empty DP_BOUND must vanish, not become ""
      $DP_BOUND kubectl get events -n "$ns" --field-selector "involvedObject.name=$pod" \
        -o jsonpath='{range .items[*]}{.lastTimestamp}{" "}{.reason}{": "}{.message}{"\n"}{end}' 2>&1 \
        || echo "(reading this pod's events $(dp_read_outcome "$?" "$DP_READ_TIMEOUT" "$DP_BOUND"))"

      if [ -z "$podip" ]; then
        echo
        echo "=== pod has no podIP; IP-specific route/conntrack capture skipped ==="
        echo "Node-global Cilium/OVN state and pod allocation events remain captured."
      fi

      if [ -n "$podip" ] && [ -n "$agent" ]; then
        echo
        echo "=== cilium-dbg bpf ct list global | grep $podip (node=$node agent=$agent) ==="
        timeout 25 kubectl exec -n "$CILIUM_NS" "$agent" -c cilium-agent -- \
          sh -c "cilium-dbg bpf ct list global 2>/dev/null | grep -F '$podip' || echo 'no CT entries for $podip'" 2>&1 || true
      fi

      cni=$(pod_on_node "$KUBEOVN_NS" app=kube-ovn-cni "$node")
      if [ -n "$podip" ] && [ -n "$cni" ]; then
        echo
        echo "=== host netns: ip route get $podip (via kube-ovn cni-server) ==="
        timeout 15 kubectl exec -n "$KUBEOVN_NS" "$cni" -c cni-server -- \
          ip route get "$podip" 2>&1 || true

        echo
        echo "=== host netns: kernel conntrack for $podip ==="
        # Under enable-host-legacy-routing the host->local-pod path is in the
        # kernel netfilter conntrack table, NOT cilium BPF -- this is the
        # authoritative table for the transient. Prefer the conntrack CLI; fall
        # back to /proc/net/nf_conntrack when it is absent from the image.
        timeout 15 kubectl exec -n "$KUBEOVN_NS" "$cni" -c cni-server -- \
          sh -c "if command -v conntrack >/dev/null 2>&1; then conntrack -L 2>/dev/null | grep -F '$podip' || echo 'no conntrack entries for $podip'; else grep -F '$podip' /proc/net/nf_conntrack 2>/dev/null || echo 'no conntrack CLI; no /proc/net/nf_conntrack match for $podip'; fi" 2>&1 || true
      fi

      if [ -n "$central" ]; then
        echo
        echo "=== OVN Port_Binding / Logical_Switch_Port for $pod.$ns ==="
        # kube-ovn names the OVN logical port <pod>.<namespace>.
        timeout 20 kubectl exec -n "$KUBEOVN_NS" "$central" -c ovn-central -- \
          ovn-sbctl --no-leader-only find port_binding "logical_port=$pod.$ns" 2>&1 || true
        timeout 20 kubectl exec -n "$KUBEOVN_NS" "$central" -c ovn-central -- \
          ovn-nbctl --no-leader-only find logical_switch_port "name=$pod.$ns" 2>&1 || true
      fi

      if [ -n "$ovs" ]; then
        echo
        echo "=== OVS interface ovn-installed flag + ts for iface-id=$pod.$ns (ovs pod $ovs) ==="
        # kube-ovn stamps external_ids:ovn-installed (+ -ts) on the pod's OVS
        # interface once ovn-controller reports the port programmed -- this is
        # the barrier the CNI waits on. The OVS interface name is opaque, so
        # look it up by iface-id (<pod>.<ns>), then read the flag + timestamp.
        # An ovn-installed-ts set early (before physical_flow_output installed
        # the local-delivery flow, see node-$node.txt) is the I-P-lag signature.
        ovsif=$(timeout 20 kubectl exec -n "$KUBEOVN_NS" "$ovs" -c openvswitch -- \
          ovs-vsctl --no-heading --columns=name find interface "external_ids:iface-id=$pod.$ns" 2>/dev/null \
          | head -n 1 | tr -d '" ')
        if [ -n "$ovsif" ]; then
          echo "ovs interface = $ovsif"
          timeout 20 kubectl exec -n "$KUBEOVN_NS" "$ovs" -c openvswitch -- \
            ovs-vsctl get interface "$ovsif" external_ids:ovn-installed external_ids:ovn-installed-ts 2>&1 || true
        else
          echo "no OVS interface with external_ids:iface-id=$pod.$ns"
        fi
      fi
    } > "$pf" 2>&1 || true
  done
  log "host->pod data-plane capture complete"
  }
fi

# ============================================================================ #
# LoadBalancer-datapath capture (see the header block for the full rationale).  #
# Independent of the NotReady-pod path above: it fires for a Service            #
# type=LoadBalancer whose external IP is unreachable even though its backend is #
# Ready, which the pod path cannot see. Everything below is bounded + best-     #
# effort and never changes the job outcome.                                     #
# ============================================================================ #

# host_http_probe <node> <lbip> <port> -- one bounded reachability probe of the
# LB IP from <node>'s host netns (via the hostNetwork kube-ovn cni-server, so the
# probe traverses the same host->cross-node->backend datapath the flake breaks).
# Echoes "ok" / "fail" per the result, "unknown" when the cni-server lookup did
# not answer so no probe could be attempted, or nothing when the image ships
# no probe client (the decision helper treats no-attempt as skip). Prefers a pure
# TCP connect (nc -z) so a non-HTTP backend is not misread as unreachable; the
# curl/wget fallbacks send HTTP and so fail-toward-capture on a non-HTTP port,
# the safe direction (capture is cheap; a missed broken LB is not). Doubles as
# the traffic generator for the tcpdumps.
host_http_probe() {
  _hp_node=$1; _hp_ip=$2; _hp_port=$3
  _hp_cni=$(pod_on_node "$KUBEOVN_NS" app=kube-ovn-cni "$_hp_node"); _hp_rc=$?
  # A lookup that never answered is not a node without a cni-server. Emitting
  # nothing here is indistinguishable from a probe that ran and said nothing,
  # and the caller reads zero outcomes as "reachable" -- a verdict about an
  # address this script never reached. The token says so instead.
  if [ "$_hp_rc" -ne 0 ]; then
    echo unknown
    return 0
  fi
  [ -n "$_hp_cni" ] || return 0
  # The LB IP/port are embedded as inner single-quoted literals (same idiom as
  # the pod-path captures above) so the inner shell never re-splits them.
  timeout 12 kubectl exec -n "$KUBEOVN_NS" "$_hp_cni" -c cni-server -- \
    sh -c "
      if command -v nc >/dev/null 2>&1; then
        nc -z -w 5 '$_hp_ip' '$_hp_port' >/dev/null 2>&1 && echo ok || echo fail
      elif command -v curl >/dev/null 2>&1; then
        curl -sS -o /dev/null --max-time 6 --connect-timeout 5 'http://$_hp_ip:$_hp_port/' >/dev/null 2>&1 && echo ok || echo fail
      elif command -v wget >/dev/null 2>&1; then
        wget -q -T 6 -O /dev/null 'http://$_hp_ip:$_hp_port/' >/dev/null 2>&1 && echo ok || echo fail
      fi
    " 2>/dev/null || true
}

# ovs_iface_for <node> <iface-id> -- the OVS interface name on <node> whose
# external_ids:iface-id matches (kube-ovn stamps <pod>.<ns>); empty if none. Used
# to point the endpoint-node tcpdump at the backend's host-side tap.
ovs_iface_for() {
  _oi_ovs=$(pod_on_node "$KUBEOVN_NS" app=ovs "$1")
  [ -n "$_oi_ovs" ] || return 0
  timeout 20 kubectl exec -n "$KUBEOVN_NS" "$_oi_ovs" -c openvswitch -- \
    ovs-vsctl --no-heading --columns=name find interface "external_ids:iface-id=$2" 2>/dev/null \
    | head -n 1 | tr -d '" '
}

# capture_lb_node <node> <role> <lbip> <nodeport> <endpointip> <outfile>
# -- the static (non-tcpdump) host-side captures on one node for a failing LB.
# role is ANNOUNCER or ENDPOINT and is stamped on every block so the two halves
# of the path are unambiguous in the artifact.
capture_lb_node() {
  _n=$1; _role=$2; _lbip=$3; _np=$4; _epip=$5; _of=$6
  _agent=$(pod_on_node "$CILIUM_NS" k8s-app=cilium "$_n"); _lb_agent_ok=$?
  _ovs=$(pod_on_node "$KUBEOVN_NS" app=ovs "$_n"); _lb_ovs_ok=$?
  _cni=$(pod_on_node "$KUBEOVN_NS" app=kube-ovn-cni "$_n"); _lb_cni_ok=$?
  _lb_a=${_agent:-$([ "$_lb_agent_ok" -eq 0 ] && echo '<none>' || echo '<unknown>')}
  _lb_o=${_ovs:-$([ "$_lb_ovs_ok" -eq 0 ] && echo '<none>' || echo '<unknown>')}
  _lb_c=${_cni:-$([ "$_lb_cni_ok" -eq 0 ] && echo '<none>' || echo '<unknown>')}
  {
    echo
    echo "---------------- $_role node=$_n (cilium=$_lb_a ovs=$_lb_o cni=$_lb_c) ----------------"

    if [ -n "$_agent" ]; then
      echo
      echo "=== [$_role $_n] cilium-dbg bpf lb list | grep LB IP / nodePort -- host cilium LB->backend programming ==="
      # Answers the first fork: if the host cilium has NO LB map entry for the
      # LB IP or the nodePort, the fault is host-cilium-not-programming; if it
      # does, suspicion shifts to kube-ovn delivery (the captures below).
      timeout 25 kubectl exec -n "$CILIUM_NS" "$_agent" -c cilium-agent -- \
        sh -c "cilium-dbg bpf lb list 2>/dev/null | grep -E '$_lbip|:$_np' || echo 'no bpf lb entry for $_lbip or nodePort $_np'" 2>&1 || true
    fi

    if [ -n "$_cni" ]; then
      echo
      echo "=== [$_role $_n] host netns: kernel conntrack -d $_lbip (via cni-server) ==="
      timeout 15 kubectl exec -n "$KUBEOVN_NS" "$_cni" -c cni-server -- \
        sh -c "if command -v conntrack >/dev/null 2>&1; then conntrack -L -d '$_lbip' 2>/dev/null || echo 'no conntrack entries for $_lbip'; else grep -F '$_lbip' /proc/net/nf_conntrack 2>/dev/null || echo 'no conntrack CLI; no /proc/net/nf_conntrack match for $_lbip'; fi" 2>&1 || true

      echo
      echo "=== [$_role $_n] host netns: ip neigh (LB IP $_lbip, endpoint IP $_epip) ==="
      timeout 15 kubectl exec -n "$KUBEOVN_NS" "$_cni" -c cni-server -- \
        sh -c "ip neigh 2>/dev/null | grep -E '$_lbip|$_epip' || echo 'no neigh entry for $_lbip or $_epip'" 2>&1 || true
    fi

    if [ -n "$_ovs" ]; then
      echo
      echo "=== [$_role $_n] ovs-ofctl dump-flows br-int | grep nodePort $_np / endpoint $_epip ==="
      timeout 25 kubectl exec -n "$KUBEOVN_NS" "$_ovs" -c openvswitch -- \
        sh -c "ovs-ofctl dump-flows br-int 2>/dev/null | grep -E '$_np|$_epip' || echo 'no br-int flow matching nodePort $_np or endpoint $_epip'" 2>&1 || true

      echo
      echo "=== [$_role $_n] ovn-controller.log decisive lines ==="
      timeout 20 kubectl exec -n "$KUBEOVN_NS" "$_ovs" -c openvswitch -- \
        sh -c 'grep -E "physical_flow_output|if_status_mgr|took [0-9]+ ?ms|recompute|Unreasonably long" /var/log/ovn/ovn-controller.log 2>/dev/null | tail -n 200 || echo "no matching lines in /var/log/ovn/ovn-controller.log"' 2>&1 || true
    fi
  } >> "$_of" 2>&1 || true
}

# capture_lb_datapath: enumerate LBs, gate on a live probe, and characterise the
# announcer/endpoint datapath for any LB whose every probe fails. Wraps the whole
# per-LB body in `|| true`-guarded, time-boxed captures so it is always best-
# effort and self-limiting (MAX_LBS cap + per-command timeouts).
capture_lb_datapath() {
  # shellcheck disable=SC2086  # empty DP_LIST_BOUND must vanish, not become ""
  _raw=$($DP_LIST_BOUND kubectl get svc -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.type}{"|"}{.status.loadBalancer.ingress[0].ip}{"|"}{.spec.ports[0].port}{"|"}{.spec.ports[0].nodePort}{"|"}{.spec.externalTrafficPolicy}{"\n"}{end}' \
    2>"${DP_ERR:-/dev/null}")
  _raw_rc=$?
  # Unconditional, like every other read's note: a list can fail AFTER emitting
  # rows -- a bound firing mid-stream leaves output on stdout and 124 in $? --
  # and gating this on emptiness would let a partial inventory be captured as a
  # complete one. The pod list splits the same way, an unconditional note here
  # and the empty-versus-unanswered distinction below.
  if [ "$_raw_rc" -ne 0 ]; then
    log "listing services $(dp_read_outcome "$_raw_rc" "$DP_LIST_TIMEOUT" "$DP_LIST_BOUND" "$DP_ERR"); any LoadBalancer it did not name is missing from the capture below"
  fi
  _lbs=$(printf '%s\n' "$_raw" | lb_filter_services)
  if [ -z "$_lbs" ] && [ "$_raw_rc" -ne 0 ]; then
    # A Service list that never answered is not a cluster without
    # LoadBalancers, the same distinction the pod list and the ovn-central
    # lookup make.
    log "whether any LoadBalancer needs capturing is unknown -- skipping LB-datapath capture"
    return 0
  fi
  if [ -z "$_lbs" ]; then
    log "no Service type=LoadBalancer with an ingress IP -- skipping LB-datapath capture"
    return 0
  fi

  _lbcount=$(printf '%s\n' "$_lbs" | wc -l | tr -d ' ')
  log "probing $_lbcount LoadBalancer service(s); heavy-capturing up to $MAX_LBS unreachable one(s) -> $OUT/lb-*.txt"

  # MetalLB speaker logs once, prefixed with each speaker's node (hostNetwork, so
  # .spec.nodeName IS the announcing node). Kept as an artifact file that
  # lb_announcer_node greps per LB. A blank file is fine -- the announcer just
  # reports <unknown> and the probe falls back to the endpoint node.
  _speakerlog="$OUT/lb-speaker-logs.txt"
  : > "$_speakerlog" 2>/dev/null || _speakerlog=""
  # shellcheck disable=SC2086  # empty DP_BOUND must vanish, not become ""
  _speakers=$($DP_BOUND kubectl get pod -n "$METALLB_NS" -l "$SPEAKER_SELECTOR" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"\n"}{end}' 2>"${DP_ERR:-/dev/null}")
  _speakers_rc=$?
  if [ "$_speakers_rc" -ne 0 ]; then
    # Same reason: a list that failed after naming speakers still resolves an
    # announcer from the ones it named, so the note says what is missing rather
    # than what was given up on.
    log "listing metallb speakers $(dp_read_outcome "$_speakers_rc" "$DP_READ_TIMEOUT" "$DP_BOUND" "$DP_ERR"); any speaker it did not name is missing from the announcer lookup"
  fi
  if [ -n "$_speakers" ] && [ -n "$_speakerlog" ]; then
    printf '%s\n' "$_speakers" | while IFS='|' read -r _sp _spnode; do
      [ -n "$_sp" ] && [ -n "$_spnode" ] || continue
      timeout 15 kubectl logs -n "$METALLB_NS" "$_sp" -c speaker --tail=2000 2>/dev/null \
        | awk -v n="$_spnode" '{ print n "\t" $0 }' >> "$_speakerlog" 2>/dev/null || true
    done
  fi

  # Counts LBs actually CAPTURED (heavy capture performed), not enumerated, so the
  # MAX_LBS cap only bounds failing LBs -- reachable/skipped ones below never
  # increment it and a broken LB enumerated after many reachable ones still gets
  # captured. The gate lives on the capture branch (lb_budget_ok), not here.
  _captured=0
  printf '%s\n' "$_lbs" | {
    while IFS='|' read -r _ns _name _type _lbip _port _np _etp; do
      [ -n "$_lbip" ] || continue
      _lbport="${_port:-0}"

      # EndpointSlice backend for this Service (first ready, addressed endpoint).
      # shellcheck disable=SC2086  # empty DP_BOUND must vanish, not become ""
      _eps=$($DP_BOUND kubectl get endpointslices -n "$_ns" \
        -l "kubernetes.io/service-name=$_name" \
        -o jsonpath='{range .items[*]}{range .endpoints[*]}{.addresses[0]}{"|"}{.nodeName}{"|"}{.targetRef.namespace}{"|"}{.targetRef.name}{"|"}{.conditions.ready}{"\n"}{end}{end}' \
        2>/dev/null)
      _backend=$(printf '%s\n' "$_eps" | lb_first_ready_endpoint)
      _epip=$(printf '%s' "$_backend" | cut -d'|' -f1)
      _epnode=$(printf '%s' "$_backend" | cut -d'|' -f2)
      _eptns=$(printf '%s' "$_backend" | cut -d'|' -f3)
      _eptname=$(printf '%s' "$_backend" | cut -d'|' -f4)
      # shellcheck disable=SC2086  # empty DP_BOUND must vanish, not become ""
      _eptport=$($DP_BOUND kubectl get endpointslices -n "$_ns" \
        -l "kubernetes.io/service-name=$_name" \
        -o jsonpath='{.items[0].ports[0].port}' 2>/dev/null)

      # Announcer node = node of the most recent serviceAnnounced for the IP.
      _annode=$(lb_announcer_node "$_lbip" < "${_speakerlog:-/dev/null}")

      _of="$OUT/lb-$_ns-$_name.txt"
      {
        echo "################################################################"
        echo "# LB $_ns/$_name  ip=$_lbip port=$_lbport nodePort=${_np:-<none>} etp=${_etp:-<default>}"
        echo "# backend: ip=${_epip:-<none>} node=${_epnode:-<none>} pod=${_eptns:-?}/${_eptname:-?} targetPort=${_eptport:-<none>}"
        echo "# announcer node: ${_annode:-<unknown>}"
        echo "################################################################"
      } > "$_of" 2>&1 || true

      # Gate: probe the LB IP from the announcer node's host netns (fall back to
      # the endpoint node if the announcer is unknown). Reachable -> record and
      # skip the heavy capture; unreachable -> characterise both hops.
      _probenode="${_annode:-$_epnode}"
      _decision=skip
      if [ -n "$_probenode" ] && [ "$_lbport" != "0" ]; then
        _decision=$( { host_http_probe "$_probenode" "$_lbip" "$_lbport"
                       host_http_probe "$_probenode" "$_lbip" "$_lbport"
                       host_http_probe "$_probenode" "$_lbip" "$_lbport"; } | lb_capture_decision )
      fi

      if [ "$_decision" = "unknown" ]; then
        echo "probe: whether the LB is reachable from ${_probenode:-<none>} is unknown -- the cni-server lookup did not answer, so no probe ran (no heavy capture)" >> "$_of" 2>&1 || true
        log "LB $_ns/$_name ($_lbip) not probed -- the cni-server lookup did not answer"
        continue
      fi

      if [ "$_decision" != "capture" ]; then
        echo "probe: LB reachable or not probeable from ${_probenode:-<none>} -- reachable, skipped (no heavy capture)" >> "$_of" 2>&1 || true
        log "LB $_ns/$_name ($_lbip) reachable or not probeable -- skipped"
        continue
      fi

      # Heavy-capture budget: only failing LBs consume MAX_LBS (reachable ones
      # skipped above without counting). Stop once the cap's worth of broken LBs
      # have been captured; remaining ones are left to the outer wall-clock bound.
      if [ "$(lb_budget_ok "$_captured" "$MAX_LBS")" != "yes" ]; then
        echo "probe: LB IP unreachable from node $_probenode but MAX_LBS=$MAX_LBS captured cap reached -- NOT characterised" >> "$_of" 2>&1 || true
        log "reached MAX_LBS=$MAX_LBS captured cap; further unreachable LB(s) NOT characterised"
        break
      fi
      _captured=$((_captured + 1))

      log "LB $_ns/$_name ($_lbip) UNREACHABLE -- capturing announcer/endpoint datapath"
      {
        echo
        echo "probe: LB IP unreachable from node $_probenode (every probe failed) -- heavy capture follows"
      } >> "$_of" 2>&1 || true

      # Static host-side captures on each hop.
      if [ -n "$_annode" ]; then
        capture_lb_node "$_annode" ANNOUNCER "$_lbip" "${_np:-0}" "${_epip:-0.0.0.0}" "$_of"
      fi
      if [ -n "$_epnode" ] && [ "$_epnode" != "$_annode" ]; then
        capture_lb_node "$_epnode" ENDPOINT "$_lbip" "${_np:-0}" "${_epip:-0.0.0.0}" "$_of"
      elif [ -n "$_epnode" ] && [ "$_epnode" = "$_annode" ]; then
        echo "(endpoint node == announcer node $_annode -- single-node path, no cross-node hop)" >> "$_of" 2>&1 || true
      fi

      # Live tcpdump on both hops WHILE the probe is replayed: announcer geneve
      # tunnel egress + endpoint backend tap ingress. Shows whether the packet
      # crosses announcer->endpoint and reaches the backend's host-side iface.
      _an_cni=$(pod_on_node "$KUBEOVN_NS" app=kube-ovn-cni "${_annode:-}")
      _en_cni=$(pod_on_node "$KUBEOVN_NS" app=kube-ovn-cni "${_epnode:-}")
      _en_iface="$GENEVE_IFACE"
      if [ -n "$_eptname" ] && [ -n "$_eptns" ]; then
        _cand=$(ovs_iface_for "${_epnode:-}" "$_eptname.$_eptns")
        [ -n "$_cand" ] && _en_iface="$_cand"
      fi

      _an_pcap="$OUT/lb-$_ns-$_name.tcpdump-announcer.txt"
      _en_pcap="$OUT/lb-$_ns-$_name.tcpdump-endpoint.txt"
      _an_td=""
      _en_td=""
      if [ -n "$_an_cni" ]; then
        {
          echo "# ANNOUNCER tcpdump node=${_annode:-<none>} iface=$GENEVE_IFACE filter='host $_lbip or host ${_epip:-0.0.0.0}'"
          timeout 15 kubectl exec -n "$KUBEOVN_NS" "$_an_cni" -c cni-server -- \
            sh -c "timeout 10 tcpdump -n -i '$GENEVE_IFACE' -c 60 'host $_lbip or host ${_epip:-0.0.0.0}' 2>&1 || true"
        } > "$_an_pcap" 2>&1 &
        _an_td=$!
      fi
      if [ -n "$_en_cni" ]; then
        {
          echo "# ENDPOINT tcpdump node=${_epnode:-<none>} iface=$_en_iface filter='host $_lbip or host ${_epip:-0.0.0.0} or port ${_np:-0}'"
          timeout 15 kubectl exec -n "$KUBEOVN_NS" "$_en_cni" -c cni-server -- \
            sh -c "timeout 10 tcpdump -n -i '$_en_iface' -c 60 'host $_lbip or host ${_epip:-0.0.0.0} or port ${_np:-0}' 2>&1 || true"
        } > "$_en_pcap" 2>&1 &
        _en_td=$!
      fi

      # Give the captures a moment to attach, then drive the probe traffic and
      # collect. Bounded by the inner tcpdump timeout/-c and the exec timeout.
      if [ -n "$_an_td" ] || [ -n "$_en_td" ]; then
        sleep 2
        host_http_probe "$_probenode" "$_lbip" "$_lbport" >/dev/null 2>&1 || true
        host_http_probe "$_probenode" "$_lbip" "$_lbport" >/dev/null 2>&1 || true
        [ -n "$_an_td" ] && { wait "$_an_td" 2>/dev/null || true; }
        [ -n "$_en_td" ] && { wait "$_en_td" 2>/dev/null || true; }
      fi

      # STRETCH / TODO (deferred -- needs tenant-cluster access, not host-side):
      #   The one hop this cannot reach is INSIDE the worker VMI. To finish the
      #   chain, exec/console into the tenant cluster (virtctl console / SSH to
      #   the worker VMI) and capture, in-guest:
      #     - `cilium-dbg bpf lb list | grep <tenant-nodePort>` -- did the TENANT
      #       cilium program the nodePort->pod translation? (separates a
      #       tenant-side miss from a host-side delivery miss);
      #     - `tcpdump -ni eth0 port <tenant-nodePort>` -- did the packet even
      #       arrive on the VMI's NIC?
      #   Deferred because it needs a tenant kubeconfig/virtctl that neither
      #   caller of this diagnostic has; the host-side ANNOUNCER/ENDPOINT split
      #   already localises the failing hop to host-cilium vs kube-ovn delivery.
    done
    log "LoadBalancer-datapath capture complete"
  }
}

capture_lb_datapath

# The stderr sink is scratch, not evidence: everything worth keeping from it is
# already quoted into a note above. Removed here rather than from an EXIT trap,
# which this repo's suites ban. This is the only exit reachable once the sink
# exists -- the two earlier ones run before it is created -- so the file leaks
# only when the call-site backstop kills the script mid-run, into the runner's
# TMPDIR.
[ -n "$DP_ERR" ] && rm -f "$DP_ERR"
[ -n "$_POD_MEMO" ] && rm -f "$_POD_MEMO"

exit 0
