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

@test "networking change triggers full suite" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "packages/system/cilium/values.yaml" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    # Full suite means more than 5 suites
    [ "$(echo "$output" | wc -w)" -gt 5 ]
}

@test "library change triggers full suite" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "packages/library/cozy-lib/templates/_helpers.tpl" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    [ "$(echo "$output" | wc -w)" -gt 5 ]
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
    [ "$(echo "$output" | wc -w)" -gt 5 ]
}

@test "chainsaw config change triggers full suite" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "hack/e2e-chainsaw/.chainsaw.yaml" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    [ "$(echo "$output" | wc -w)" -gt 5 ]
}

@test "install bats triggers full suite" {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "hack/e2e-install-cozystack.bats" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    [ "$(echo "$output" | wc -w)" -gt 5 ]
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
    [ "$(echo "$output" | wc -w)" -gt 5 ]
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
    rm -rf "$tmp"
    [ "$(echo "$output" | wc -w)" -gt 5 ]
}

@test "the fork e2e workflow triggers full suite" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    echo ".github/workflows/e2e-fork.yaml" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    rm -rf "$tmp"
    [ "$(echo "$output" | wc -w)" -gt 5 ]
}

@test "pkg/ triggers full suite (shipped Go code)" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "pkg/cozystack/registry.go" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    rm -rf "$tmp"
    [ "$(echo "$output" | wc -w)" -gt 5 ]
}

@test "go.mod triggers full suite" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "go.mod" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    rm -rf "$tmp"
    [ "$(echo "$output" | wc -w)" -gt 5 ]
}

@test "hack/lib helper triggers full suite" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "hack/lib/image-refs.sh" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    rm -rf "$tmp"
    [ "$(echo "$output" | wc -w)" -gt 5 ]
}

@test "an unclassified path escalates instead of selecting nothing" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    echo "brand-new-top-level/thing.conf" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources" 2>/dev/null)
    rm -rf "$tmp"
    [ "$(echo "$output" | wc -w)" -gt 5 ]
}

@test "inert repo meta selects nothing" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    printf '%s\n' .gitignore LICENSE .pre-commit-config.yaml > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    rm -rf "$tmp"
    [ -z "$output" ]
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
    rm -rf "$tmp"
    [ "$(echo "$output" | wc -w)" -gt 5 ]
}

@test "a README inside an escalating tree stays inert" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    # packages/core/ escalates, but *.md is matched before that so a doc edit
    # under it does not burn a full run.
    echo "packages/core/installer/README.md" > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    rm -rf "$tmp"
    [ -z "$output" ]
}

@test "an inert path alongside a real one does not mask the selection" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    printf '%s\n' .gitignore packages/apps/postgres/values.yaml > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    rm -rf "$tmp"
    [ "$output" = "postgres" ]
}

# The classification above is only total if every line reaches the loop that
# applies it. POSIX read assigns the last line and returns non-zero when the
# input has no trailing newline, so a plain `while read` drops it, and the
# fall-through that escalates an unrecognised path lives inside the body that
# drop skips. `git diff --name-only` always terminates its output, so the bug is
# invisible to a caller that pipes it; a caller assembling the list itself sees
# it immediately. Both cases below are red without `|| [ -n "$file" ]`.
#
# These two clean up inline rather than through `trap ... EXIT`: an EXIT trap
# replaces the one the bats binary installs for its own bookkeeping, and a test
# that fails under it can print no TAP line at all, which is the opposite of
# what a regression pin is for.

@test "an unterminated last line is still classified" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    printf '%s' packages/apps/postgres/values.yaml > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    rm -rf "$tmp"
    [ "$output" = "postgres" ]
}

@test "an unterminated unclassified last line still escalates" {
    tmp=$(mktemp -d)
    cp -r packages/core/platform/sources "$tmp/sources"
    # The unclassified path is the one the drop would eat, so without the guard
    # the escalation never fires and the selection comes back empty — the exact
    # silent-green this classification exists to remove.
    printf 'docs/x.md\n%s' brand-new/thing.conf > "$tmp/diff"
    output=$(hack/select-e2e.sh "$tmp/diff" "$tmp/sources")
    rm -rf "$tmp"
    [ "$(echo "$output" | wc -w)" -gt 5 ]
}
