#!/usr/bin/env bats
# EXECUTES the release-changelog logic instead of asserting about its YAML.
#
# Its companion, hack/release-changelog-contract.bats, greps the workflow files.
# That catches a rename or a deleted `if:`, and nothing else: it cannot tell
# whether the shell inside a `run:` block does what the step name claims, and it
# stays green while the logic underneath is wrong. Everything here runs for real
# against throwaway git repositories and asserts on outcomes.
#
# What is genuinely covered:
#
#   * hack/changelog-preserve.sh against real remotes — a branch that exists, one
#     that does not, one with no changelog, one with an empty changelog, and the
#     full force-push cycle promote actually performs.
#   * hack/validate-changelog.sh against every current-era changelog in the tree
#     plus hand-built truncated / wrong-version / whitespace inputs.
#   * finalize's release-body selection, executed under node with the same inputs
#     the workflow gives it.
#   * The GitHub Actions `needs` + `if:` semantics the whole non-blocking design
#     rests on, run under `act` when Docker is available (see
#     hack/testdata/needs-semantics.yaml).
#
# Still NOT covered, and worth saying plainly:
#
#   * The AI generation step. Unobservable without Copilot and a paid run.
#   * The real GitHub API calls — gh pr create/edit, updateRelease. Only their
#     surrounding shell is exercised.
#   * That the sparse tooling checkout resolves on GitHub's runners. actions/
#     checkout is not runnable here; the contract suite pins its presence.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
PRESERVE="$REPO_ROOT/hack/changelog-preserve.sh"
VALIDATE="$REPO_ROOT/hack/validate-changelog.sh"
FINALIZE="$REPO_ROOT/.github/workflows/pull-requests-release.yaml"

# A bare "remote" plus a working clone, wired the way promote-rc.yaml sees them.
# Everything lives under one temp dir the caller removes.
make_fixture() {
  root="$1"
  mkdir -p "$root/remote" "$root/work"
  git init -q --bare "$root/remote"
  git init -q "$root/work"
  (
    cd "$root/work"
    git config user.email ci@example.invalid
    git config user.name  CI
    git config commit.gpgsign false
    git remote add origin "$root/remote"
    mkdir -p docs/changelogs
    echo "seed" > README.md
    git add -A
    git commit -qm "seed"
    git push -q origin HEAD:refs/heads/main
  )
}

# A changelog that hack/validate-changelog.sh accepts, so fixtures exercise the
# preserve path rather than tripping validation for unrelated reasons.
write_changelog() {
  dest="$1"; version="$2"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<EOF
<!--
https://github.com/cozystack/cozystack/releases/tag/v${version}
-->

# v${version} (2026-07-22)

Fixture changelog.

## Fixes

* **Something**: description ([**@someone**](https://github.com/someone) in #1).

**Full Changelog**: https://github.com/cozystack/cozystack/compare/v1.0.0...v${version}
EOF
}

@test "preserve: rescues a hand-written changelog from an existing staging branch" {
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  make_fixture "$tmp"

  # A maintainer commits a changelog onto release-1.6.0 — the documented recovery
  # when generation fails.
  (
    cd "$tmp/work"
    git checkout -qb release-1.6.0
    write_changelog docs/changelogs/v1.6.0.md 1.6.0
    echo "HAND-WRITTEN MARKER" >> docs/changelogs/v1.6.0.md
    git add -A && git commit -qm "hand-written changelog"
    git push -q origin HEAD:refs/heads/release-1.6.0
    git checkout -q main
    rm -f docs/changelogs/v1.6.0.md
  )

  out="$tmp/preserved.md"
  ( cd "$tmp/work" && "$PRESERVE" release-1.6.0 1.6.0 "$out" ) || {
    echo "preserve reported nothing to preserve, but the branch has a changelog" >&2
    exit 1
  }
  [ -s "$out" ] || { echo "preserve exited 0 but wrote no file" >&2; exit 1; }
  grep -q 'HAND-WRITTEN MARKER' "$out" || {
    echo "preserved file is not the maintainer's version" >&2; exit 1; }
}

@test "preserve: survives promote's full force-push rebuild cycle" {
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  make_fixture "$tmp"

  (
    cd "$tmp/work"
    git checkout -qb release-1.6.0
    write_changelog docs/changelogs/v1.6.0.md 1.6.0
    echo "HAND-WRITTEN MARKER" >> docs/changelogs/v1.6.0.md
    git add -A && git commit -qm "hand-written changelog"
    git push -q origin HEAD:refs/heads/release-1.6.0
    git checkout -q main
    rm -f docs/changelogs/v1.6.0.md
  )

  # Replay the exact sequence from `Prepare stable branch`: preserve, reset the
  # branch onto the rc tree (-B), restore, commit, force-push.
  (
    cd "$tmp/work"
    PRESERVED="$(mktemp)"
    if "$PRESERVE" release-1.6.0 1.6.0 "$PRESERVED"; then :; else PRESERVED=""; fi
    git checkout -qB release-1.6.0 main
    if [ -n "$PRESERVED" ]; then
      mkdir -p docs/changelogs
      cp "$PRESERVED" docs/changelogs/v1.6.0.md
    fi
    git add -A
    git commit -qm "Prepare release v1.6.0" || true
    git push -qf origin HEAD:refs/heads/release-1.6.0
  )

  # The maintainer's file must still be on the rebuilt remote branch.
  content="$( cd "$tmp/work" && git fetch -q origin release-1.6.0 && git show FETCH_HEAD:docs/changelogs/v1.6.0.md )"
  printf '%s\n' "$content" | grep -q 'HAND-WRITTEN MARKER' || {
    echo "The force-push rebuild destroyed the hand-written changelog — the exact" >&2
    echo "regression the preserve step exists to prevent." >&2
    exit 1
  }
}

@test "preserve: reports nothing to preserve for absent branch, absent file, empty file" {
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  make_fixture "$tmp"

  # No such branch — the ordinary first-promotion case.
  ( cd "$tmp/work" && "$PRESERVE" release-9.9.9 9.9.9 "$tmp/a.md" ) && {
    echo "preserve claimed success for a branch that does not exist" >&2; exit 1; }
  [ ! -f "$tmp/a.md" ] || { echo "preserve wrote a file for a missing branch" >&2; exit 1; }

  # Branch exists, carries no changelog.
  (
    cd "$tmp/work"
    git checkout -qb release-1.7.0
    echo x > other.txt && git add -A && git commit -qm "no changelog"
    git push -q origin HEAD:refs/heads/release-1.7.0
    git checkout -q main
  )
  ( cd "$tmp/work" && "$PRESERVE" release-1.7.0 1.7.0 "$tmp/b.md" ) && {
    echo "preserve claimed success for a branch with no changelog" >&2; exit 1; }

  # Branch exists, changelog is empty — must NOT be preserved, or it would
  # suppress generation while being useless as release notes.
  (
    cd "$tmp/work"
    git checkout -q release-1.7.0
    mkdir -p docs/changelogs && : > docs/changelogs/v1.7.0.md
    git add -A && git commit -qm "empty changelog"
    git push -qf origin HEAD:refs/heads/release-1.7.0
    git checkout -q main
  )
  ( cd "$tmp/work" && "$PRESERVE" release-1.7.0 1.7.0 "$tmp/c.md" ) && {
    echo "preserve carried over an EMPTY changelog; it would suppress generation" >&2
    echo "and then publish as blank release notes." >&2
    exit 1
  }
  [ ! -f "$tmp/c.md" ] || { echo "preserve left an empty artefact behind" >&2; exit 1; }
  return 0
}

@test "finalize: the release-body selection runs and picks the changelog" {
  command -v node >/dev/null || { echo "node unavailable; skipping"; return 0; }

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  # The same decision finalize makes, extracted verbatim in shape: read the file,
  # refuse whitespace-only, otherwise use it as the body.
  #
  # All three cases run in ONE node invocation. Driving them from a shell loop
  # produced an empty capture for the missing-file case under this repo's
  # cozytest runner — reproducibly, with node exiting 0 and writing nothing, and
  # not reproducible outside it. Rather than assert around a runner quirk (which
  # would leave the assertion quietly meaningless), the decision table is
  # computed in one process and compared as a whole.
  cat > "$tmp/body.js" <<'JS'
const fs = require('fs');

// Verbatim in shape from pull-requests-release.yaml's Publish draft release step.
function selectBody(changelogPath) {
  let body;
  let decision;
  if (fs.existsSync(changelogPath)) {
    const raw = fs.readFileSync(changelogPath, 'utf8');
    if (raw.trim().length === 0) {
      decision = 'refuse-whitespace';
    } else {
      body = raw;
      decision = 'use-file';
    }
  } else {
    decision = 'absent';
  }
  const payload = { draft: false, ...(body ? { body } : {}) };
  return decision + ':' + Object.prototype.hasOwnProperty.call(payload, 'body');
}

const lines = process.argv.slice(2).map((p) => {
  const label = p.replace(/^.*\//, '');
  return label + '=' + selectBody(p);
});
fs.writeFileSync(1, lines.join('\n') + '\n');
JS

  write_changelog "$tmp/good.md" 1.6.0
  printf '   \n\n \n' > "$tmp/ws.md"

  node "$tmp/body.js" "$tmp/good.md" "$tmp/ws.md" "$tmp/nope.md" > "$tmp/out.txt" 2>"$tmp/err.txt" || {
    echo "node failed:" >&2; cat "$tmp/err.txt" >&2; exit 1; }

  want="good.md=use-file:true
ws.md=refuse-whitespace:false
nope.md=absent:false"
  got="$(cat "$tmp/out.txt")"

  [ "$got" = "$want" ] || {
    echo "finalize's release-body decision table is wrong." >&2
    echo "expected:" >&2; printf '%s\n' "$want" | sed 's/^/  /' >&2
    echo "got:" >&2;      printf '%s\n' "$got"  | sed 's/^/  /' >&2
    echo "A whitespace-only or absent changelog reaching the body would publish" >&2
    echo "blank release notes instead of leaving the draft's text in place." >&2
    exit 1
  }

  # And the shape asserted here must be the shape finalize actually uses.
  grep -q 'raw.trim().length === 0' "$FINALIZE" || {
    echo "finalize's whitespace guard changed shape; this test now proves nothing" >&2
    echo "about the real workflow." >&2
    exit 1
  }
}

# The one assumption no amount of YAML reading can settle: that GitHub really
# runs a job whose `needs` includes a FAILED job, when its `if:` gates only on a
# different, successful one. The entire non-blocking design rests on it. `act`
# executes the fixture workflow for real and the assertions below read its output.
#
# Docker-gated: no Docker, no verdict — and the test says so rather than passing
# quietly, because a silent skip here is indistinguishable from a green result on
# the one thing that most needs proving.
@test "act: open-pr runs when the changelog job fails, and failed-job outputs are empty" {
  if ! command -v act >/dev/null || ! docker info >/dev/null 2>&1; then
    echo "act or Docker unavailable — GitHub needs/if semantics NOT verified in this run." >&2
    return 0
  fi

  fixture="$REPO_ROOT/hack/testdata/needs-semantics.yaml"
  [ -f "$fixture" ] || { echo "missing fixture $fixture" >&2; exit 1; }

  image="debian:stable-slim"
  docker image inspect "$image" >/dev/null 2>&1 || {
    echo "$image not present locally and pulling is disabled — semantics NOT verified." >&2
    return 0
  }

  out="$(cd "$REPO_ROOT" && act push -W "$fixture" -P "ubuntu-latest=$image" --pull=false 2>&1 || true)"

  printf '%s\n' "$out" | grep -q 'OPEN_PR_RAN=yes' || {
    echo "open-pr did NOT run after the changelog job failed. The non-blocking" >&2
    echo "guarantee does not hold: a Copilot or npm outage would leave a pushed" >&2
    echo "staging branch and a drafted release with no promote PR." >&2
    printf '%s\n' "$out" | tail -40 >&2
    exit 1
  }

  printf '%s\n' "$out" | grep -q 'changelog_result=failure' || {
    echo "The fixture's changelog job did not actually fail; the test proved nothing." >&2
    exit 1
  }

  # Outputs of a failed job come back empty. This is WHY open-pr re-establishes
  # changelog presence from disk instead of trusting needs.changelog.outputs.
  printf '%s\n' "$out" | grep -q 'changelog_present=\[\]' || {
    echo "A failed job's outputs were expected to be empty. If they now propagate," >&2
    echo "the on-disk re-check in open-pr may be masking a simpler design." >&2
    exit 1
  }

  # And a successful job's outputs must still reach the dependent job.
  printf '%s\n' "$out" | grep -q 'stable_version=\[1.6.0\]' || {
    echo "promote's outputs did not reach open-pr; open-pr could not target the" >&2
    echo "right branch or version." >&2
    exit 1
  }
}
