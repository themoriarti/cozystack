#!/usr/bin/env bats
# Contract for the PR title labeler in .github/workflows/pr-labeler.yaml.
#
# Every failure this guards is silent: the job either dies on a title it cannot
# handle, applies a label that does not exist, or lands a PR in the wrong area
# with no warning, and nobody reads the log of a labeler that did not label.
#
# The behavioural tests run the workflow's own github-script block under node,
# extracted from the file rather than mirrored, with `context`, `core` and
# `github` stubbed, so an edit to the script is what gets tested. node is
# required, not optional: a suite that skips when the runtime is missing goes
# green having run nothing.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/pr-labeler.yaml"

need_node() {
  command -v node >/dev/null 2>&1 && return 0
  echo "node is required to run the pr-labeler script" >&2
  return 1
}

# The `script: |` block, de-indented to plain JavaScript.
extract_script() {
  awk 'f { print substr($0, 13) } /^ +script: \|$/ { f = 1 }' "$WF" > "$1"
  [ -s "$1" ]
}

# Runs the extracted script once per title read from stdin, all in one node
# process, and prints one line per title: the title, a tab, then the applied
# labels sorted and comma-joined, or THROW: and the error message.
#
# JavaScript closing braces below are indented on purpose: hack/cozytest.sh
# rewrites any line that is exactly `}` into a shell `return 0`.
run_labeler() {
  tmp="$(mktemp -d)"
  extract_script "$tmp/script.js"
  cat > "$tmp/run.js" <<'JS'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const AsyncFunction = (async () => {}).constructor;
const fn = new AsyncFunction('context', 'core', 'github', src);
(async () => {
  const out = [];
  const titles = fs.readFileSync(0, 'utf8').split('\n').filter(Boolean);
  for (const title of titles) {
    let applied = [];
    const context = {
      repo: { owner: 'o', repo: 'r' },
      payload: { pull_request: { number: 1, title, body: '', labels: [] } },
    };
    const core = { warning() {}, info() {} };
    const github = { rest: { issues: { addLabels: async (a) => { applied = a.labels; } } } };
    try {
      await fn(context, core, github);
      out.push(title + '\t' + [...applied].sort().join(','));
    } catch (e) {
      out.push(title + '\tTHROW: ' + e.message);
    }
  }
  fs.writeFileSync(1, out.join('\n') + '\n');
})();
JS
  node "$tmp/run.js" "$tmp/script.js"
  rm -rf "$tmp"
}

# Asserts the labeler's output for each `title<TAB>labels` line on stdin.
expect_labels() {
  want="$(cat)"
  got="$(printf '%s\n' "$want" | cut -f1 | run_labeler)"
  [ "$got" = "$want" ] || {
    echo "labeler output mismatch." >&2
    echo "want:" >&2; printf '%s\n' "$want" | sed 's/^/  /' >&2
    echo "got:" >&2; printf '%s\n' "$got" | sed 's/^/  /' >&2
    return 1
  }
}

@test "the workflow under contract exists" {
  [ -f "$WF" ]
}

# A key inherited from Object.prototype resolves to a function, which is truthy,
# lands in the label set, and then kills the job on `l.startsWith`.
@test "a scope or type named after an Object.prototype member does not kill the job" {
  need_node
  expect_labels <<'EOF'
fix(constructor): x	area/uncategorized,kind/bug
fix(toString): x	area/uncategorized,kind/bug
fix(hasOwnProperty): x	area/uncategorized,kind/bug
fix(__proto__): x	area/uncategorized,kind/bug
[constructor] x	area/uncategorized
constructor: x	area/uncategorized
EOF
}

# One stripped prefix left the second one to be parsed as a bracket scope, which
# dropped the real scope and the kind, and the area/release from the first strip
# suppressed the uncategorized signal.
@test "every leading backport prefix is stripped before the title is parsed" {
  need_node
  expect_labels <<'EOF'
[Backport release-1.3] fix(linstor): x	area/release,area/storage,kind/bug
[Backport release-1.2] [Backport release-1.3] fix(linstor): x	area/release,area/storage,kind/bug
[Backport release-1.2] [Backport release-1.3] [Backport release-1.4] feat(linstor): x	area/release,area/storage,kind/feature
EOF
}

@test "an unmapped scope still falls back to area/uncategorized" {
  need_node
  expect_labels <<'EOF'
fix(no-such-scope): x	area/uncategorized,kind/bug
fix: x	area/uncategorized,kind/bug
just a sentence	area/uncategorized
EOF
}

