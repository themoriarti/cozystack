#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Unit tests for hack/select-e2e.sh
#
# cozytest.sh's awk parser recognizes only @test blocks and a bare `}` on its
# own line; there is no bats `run` or `$status`. Each test runs as a shell
# function under `set -eu -x`, so assertions are direct shell tests that exit
# non-zero on failure. setup()/teardown() are not honored — each test creates
# and cleans its own scratch dir.
#
# Run with: hack/cozytest.sh hack/select-e2e_test.bats
# -----------------------------------------------------------------------------

# Assert that a selection is the WHOLE suite list, not merely a long one.
#
# These asserts used to read `[ "$(echo "$output" | wc -w)" -gt 5 ]`, which is
# satisfied by any selection of six or more suites. The regression worth
# catching on every escalation path is partial escalation — a selector bug that
# picks most suites but not all — and a threshold cannot see it: with 21 suites
# in the tree, dropping fifteen of them still passes. Equality can.
#
# The expected set is derived the way the script's full-suite branch derives it
# rather than pinned as a literal, so adding or disabling a Chainsaw suite does
# not need an edit in fourteen places here.
#
# A helper rather than an inline one-liner because cozytest.sh runs each @test
# under `set -x`: a bare failing `[ ... ]` prints the two values already
# expanded, but not which side is which, and reading a 21-item diff off a trace
# line is exactly the moment a test stops being worth having.
full_suite_list() {
    find hack/e2e-chainsaw -mindepth 2 -maxdepth 2 -name chainsaw-test.yaml \
      | sed -e 's,^hack/e2e-chainsaw/,,' -e 's,/chainsaw-test\.yaml$,,' | sort | paste -sd ' ' -
}

assert_selection() {
    if [ "$2" != "$3" ]; then
        echo "$1" >&2
        echo "  want: $3" >&2
        echo "  got:  $2" >&2
        exit 1
    fi
}

assert_full_suite() {
    assert_selection "expected the full Chainsaw suite" "$1" "$(full_suite_list)"
}

@test "single app diff selects only that suite" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "packages/apps/postgres/values.yaml" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    [ "$output" = "postgres" ]
}

@test "operator diff selects all dependent app suites" {
    # postgres-operator is depended on by postgres-application, harbor-application
    # (Harbor uses postgres as its backing DB), and monitoring-application (Grafana
    # DB). monitoring has no chainsaw suite so it's filtered out by the selector.
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "packages/system/postgres-operator/values.yaml" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    echo "$output" | grep -wq postgres
    echo "$output" | grep -wq harbor
    if echo "$output" | grep -wq kafka; then
        echo "operator diff must not trigger full suite; got: $output" >&2
        exit 1
    fi
}

@test "engine-dependency change does not fan out via the ordering edge" {
    # cert-manager is a dependency of cozystack-engine, and every app declares
    # dependsOn cozystack-engine purely as an INSTALL-ORDERING edge (the app's
    # *-rd HelmRelease waits for the ApplicationDefinition CRD). That edge must
    # not propagate test selection: a cert-manager change selects only its
    # genuine direct dependents (postgres, harbor, ...), never unrelated apps
    # like kafka that reach cert-manager solely through the engine.
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "packages/system/cert-manager/values.yaml" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    echo "$output" | grep -wq postgres
    echo "$output" | grep -wq harbor
    if echo "$output" | grep -wq kafka; then
        echo "cert-manager change must not fan out via engine; got: $output" >&2
        exit 1
    fi
}

@test "a CNI change selects every suite the graph can reach" {
    # Named for what it measures rather than for the full suite it used to claim.
    # `packages/system/cilium` is owned by cozystack.networking and resolves
    # through the dependency graph, not through full_suite_pattern, so the
    # selection is "every suite reachable from networking" — which is 19 of the
    # 21 that exist, not all of them.
    #
    # The two it cannot reach are kuberture and securitygroup. select-e2e.sh maps
    # a source to suites only for *-application names, plus external-dns by
    # name; cozystack.kuberture and cozystack.securitygroup-controller are
    # neither, so the walk reaches them and the filter drops them. Both declare
    # cozystack.networking as a dependency, so this is the selector under-
    # selecting, not the graph being right — a CNI change that breaks either
    # controller runs neither of their suites. Tracked in #3665. Subtracted here
    # rather than papered over: closing that gap turns this test red, which is
    # the correct moment to notice — the two names below are a measurement of
    # today's selector, not a typo. The previous `wc -w -gt 5` assert passed on
    # 19 and said nothing.
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "packages/system/cilium/values.yaml" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    reachable=$(full_suite_list | tr ' ' '\n' | grep -vxE 'kuberture|securitygroup' | paste -sd ' ' -)
    assert_selection "expected every graph-reachable suite" "$output" "$reachable"
}

@test "library change triggers full suite" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "packages/library/cozy-lib/templates/_helpers.tpl" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    assert_full_suite "$output"
}

@test "docs-only diff selects nothing" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "docs/README.md" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    [ -z "$output" ]
}

@test "kubernetes-application maps to the four kubernetes suites" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "packages/apps/kubernetes/values.yaml" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    echo "$output" | grep -q "kubernetes-latest"
    echo "$output" | grep -q "kubernetes-previous"
    # The OIDC render-side suites exercise the same kubernetes app chart, so a
    # chart-only change must select them too.
    echo "$output" | grep -q "kubernetes-oidc-system"
    echo "$output" | grep -q "kubernetes-oidc-customconfig"
}

@test "dashboards-only diff selects nothing (path is plural)" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "dashboards/gpu/gpu-fleet.json" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    [ -z "$output" ]
}

@test "shared E2E helper script triggers full suite" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "hack/e2e-chainsaw/_lib/run-kubernetes.sh" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    assert_full_suite "$output"
}

@test "chainsaw config change triggers full suite" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "hack/e2e-chainsaw/.chainsaw.yaml" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    assert_full_suite "$output"
}

@test "install bats triggers full suite" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "hack/e2e-install-cozystack.bats" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    assert_full_suite "$output"
}

@test "per-suite edit selects only that suite, never escalates" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "hack/e2e-chainsaw/redis/chainsaw-test.yaml" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    [ "$output" = "redis" ]
}

@test "pull-requests workflow change triggers full suite" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo ".github/workflows/pull-requests.yaml" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    assert_full_suite "$output"
}

@test "backup example harness edit selects its app suite" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "examples/backups/postgres/run-all.sh" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    [ "$output" = "postgres" ]
}

@test "backup example without a matching suite selects nothing" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "examples/backups/no-such-app/run.sh" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources") || true
    [ -z "$output" ]
}

# --- #3392: every path is classified; unclassified escalates -----------------
#
# The bug these cover: an unrecognised path used to select nothing, both lanes
# read an empty selection as "skip Chainsaw", and the required "E2E Tests"
# status was then posted green with no suite run. Each test below pins one side
# of the classification — escalate, or skip by an explicit rule.

@test "hack/*.mk triggers full suite (build flags of every image)" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "hack/common-envs.mk" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    assert_full_suite "$output"
    rm -rf "$tmp"
}

@test "the fork e2e workflow triggers full suite" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    echo ".github/workflows/e2e-fork.yaml" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    assert_full_suite "$output"
    rm -rf "$tmp"
}

@test "pkg/ triggers full suite (shipped Go code)" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "pkg/cozystack/registry.go" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    assert_full_suite "$output"
    rm -rf "$tmp"
}

@test "go.mod triggers full suite" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "go.mod" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    assert_full_suite "$output"
    rm -rf "$tmp"
}

@test "hack/lib helper triggers full suite" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "hack/lib/image-refs.sh" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    assert_full_suite "$output"
    rm -rf "$tmp"
}

@test "an unclassified path escalates instead of selecting nothing" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "brand-new-top-level/thing.conf" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources" 2>/dev/null)
    assert_full_suite "$output"
    rm -rf "$tmp"
}

@test "inert repo meta selects nothing" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    printf '%s\n' .gitignore LICENSE .pre-commit-config.yaml > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    [ -z "$output" ]
    rm -rf "$tmp"
}

@test "a non-e2e workflow selects nothing, an e2e one still escalates" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    # .github/ is inert as a directory, but the escalation for the workflows
    # that run the suite is checked first and must win.
    echo ".github/workflows/tags.yaml" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    [ -z "$output" ]
    echo ".github/workflows/e2e-tag.yaml" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    assert_full_suite "$output"
    rm -rf "$tmp"
}

@test "a README inside an escalating tree stays inert" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    # packages/core/ escalates, but *.md is matched before that so a doc edit
    # under it does not burn a full run.
    echo "packages/core/installer/README.md" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    [ -z "$output" ]
    rm -rf "$tmp"
}

@test "an inert path alongside a real one does not mask the selection" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    printf '%s\n' .gitignore packages/apps/postgres/values.yaml > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    [ "$output" = "postgres" ]
    rm -rf "$tmp"
}

# The classification above is only total if every line reaches the loop that
# applies it. POSIX read assigns the last line and returns non-zero when the
# input has no trailing newline, so a plain `while read` drops it, and the
# fall-through that escalates an unrecognised path lives inside the body that
# drop skips. `git diff --name-only` always terminates its output, so the bug is
# invisible to a caller that pipes it; a caller assembling the list itself sees
# it immediately. Both cases below are red without `|| [ -n "$file" ]`.
#
# Cleanup here, as in every test added with this change, is the last statement
# of the body rather than a `trap ... EXIT`: that trap replaces the one the bats
# binary installs for its own bookkeeping, and a test failing under it can print
# no TAP line at all, which is the opposite of what a regression pin is for.
# Last, not before the assertion, so that `set -e` leaves the scratch directory
# behind on failure for inspection (docs/agents/e2e-testing.md §3).

@test "a broken yq is named rather than passed off as an empty graph" {
    # Both indexes are one yq each, read as `$(build_owners_index | sort -u)`,
    # so the pipeline reports sort's status and set -e never sees yq's. A
    # missing binary or a malformed PackageSource then yields an empty index,
    # every path falls through to escalation, and the run is a full suite that
    # looks exactly like intended conservatism. Nothing distinguishes it from
    # "no owners matched", so nobody is told the selector stopped working.
    #
    # The escalation is the right outcome and is asserted here too; what this
    # pins is that it comes with a line naming yq.
    #
    # The exit status is asserted as ZERO on purpose, and it is the difference
    # between this case and the two below it. What a broken yq costs is the
    # dependency graph, and the full suite is a correct answer without one, so
    # the script still answers. When the SUITE LIST is what broke there is no
    # correct answer left to give and the script exits non-zero instead. Both
    # halves are pinned so the header and docs cannot drift into claiming this
    # one reddens the gate — it does not; it is conservative and quiet.
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    mkdir "$tmp/bin"
    printf '#!/bin/sh\necho "yq: broken fixture" >&2\nexit 1\n' > "$tmp/bin/yq"
    chmod +x "$tmp/bin/yq"
    echo "packages/apps/postgres/values.yaml" > "$tmp/diff"
    rc=0
    output=$(PATH="$tmp/bin:$PATH" hack/select-e2e.sh "$tmp/diff" "$tmp/sources" 2>"$tmp/err") || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "a broken yq must still answer with the full suite, not exit $rc" >&2
        cat "$tmp/err" >&2
        exit 1
    fi
    # Matched on the script's own prefix, not on the word alone: the stub writes
    # to stderr the way a real yq does, so a bare `grep yq` passes on the
    # fixture's noise and pins nothing.
    if ! grep -q 'select-e2e:.*yq' "$tmp/err"; then
        echo "a yq failure must be reported by select-e2e itself; stderr was:" >&2
        cat "$tmp/err" >&2
        exit 1
    fi
    assert_full_suite "$output"
    rm -rf "$tmp"
}

@test "a broken find is reported rather than yielding an empty suite list" {
    # The suite list is built as `$(find ... | sed | sort)`, which reports
    # sort's status and never find's — the same blindness as the yq indexes
    # above, in a worse place: every escalation prints that list, so a silent
    # failure here turns "run everything" into a run of nothing.
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    mkdir "$tmp/bin"
    printf '#!/bin/sh\necho "find: broken fixture" >&2\nexit 1\n' > "$tmp/bin/find"
    chmod +x "$tmp/bin/find"
    echo "go.mod" > "$tmp/diff"
    rc=0
    output=$(PATH="$tmp/bin:$PATH" hack/select-e2e.sh "$tmp/diff" "$tmp/sources" 2>"$tmp/err") || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "a broken find must fail the run; it exited 0 with output: '$output'" >&2
        exit 1
    fi
    if ! grep -q 'select-e2e:.*find' "$tmp/err"; then
        echo "a find failure must be reported by select-e2e itself; stderr was:" >&2
        cat "$tmp/err" >&2
        exit 1
    fi
    rm -rf "$tmp"
}

@test "an empty suite list is fatal whatever the diff classifies as" {
    # Checked once where the list is built, not at the escalation branches,
    # because an empty list corrupts more than those. The escalations would
    # print it, and a blank selection is what both lanes read as "skip
    # Chainsaw" before posting the required status green — the outcome meaning
    # "run everything" delivering a run of nothing. But the
    # examples/backups/<app>/ rule escalates nothing and still consults the
    # list as a membership test, so with the list empty a backup-harness edit
    # that should run its suite reports nothing to run instead — and that one
    # is indistinguishable from a legitimately empty selection.
    #
    # Run from a tree whose hack/e2e-chainsaw exists but holds no
    # chainsaw-test.yaml, so find succeeds and matches nothing — the state a
    # moved directory or a wrong working directory produces. All three diff
    # classes are exercised: one that escalates, one that selects by
    # membership, and one that legitimately selects nothing. The middle two
    # exited 0 while the guard lived at the escalation branches.
    tmp=$(mktemp -d)
    script="$PWD/hack/select-e2e.sh"
    cp -r packages/core/platform/sources "$tmp/sources"
    mkdir -p "$tmp/tree/hack/e2e-chainsaw"
    for d in go.mod examples/backups/postgres/run-all.sh docs/x.md; do
        echo "$d" > "$tmp/diff"
        rc=0
        output=$(cd "$tmp/tree" && "$script" "$tmp/diff" "$tmp/sources" 2>"$tmp/err") || rc=$?
        if [ "$rc" -eq 0 ]; then
            echo "a broken suite enumeration must fail for '$d', not print '$output' and exit 0" >&2
            cat "$tmp/err" >&2
            exit 1
        fi
        if ! grep -q 'suite enumeration is broken' "$tmp/err"; then
            echo "the refusal must say why for '$d'; stderr was:" >&2
            cat "$tmp/err" >&2
            exit 1
        fi
    done
    rm -rf "$tmp"
}

@test "an unterminated last line is still classified" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    printf '%s' packages/apps/postgres/values.yaml > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    [ "$output" = "postgres" ]
    rm -rf "$tmp"
}

@test "an unterminated unclassified last line still escalates" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    # The unclassified path is the one the drop would eat, so without the guard
    # the escalation never fires and the selection comes back empty — the exact
    # silent-green this classification exists to remove.
    printf 'docs/x.md\n%s' brand-new/thing.conf > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    assert_full_suite "$output"
    rm -rf "$tmp"
}
