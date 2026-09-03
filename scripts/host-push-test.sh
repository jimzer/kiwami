#!/usr/bin/env bash
# `kiwami host push` must send the host directory and nothing else.
#
# The command exists because hosts/xps was scaffolded, staged and never
# committed - the config for rebuilding a machine lived only on that machine.
# The obvious implementation is `git push`, which would send whatever commits
# happen to be sitting in the working tree. This asserts the property the
# design rests on: a branch built from origin/main containing only the host.
#
# It needs git and the built CLI, no Linux and no VM, so it runs in `just check`
# alongside the unit tests rather than in the VM matrix.
set -euo pipefail

cyan() { printf '\033[1;36m%s\033[0m\n' "$1"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; exit 1; }
pass() { printf '\033[32mPASS\033[0m %s\n' "$1"; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kiwami="$root/cli/target/debug/kiwami"
[ -x "$kiwami" ] || cargo build --quiet --manifest-path "$root/cli/Cargo.toml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cyan "==> a repository with a host, and unrelated local work"
git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/seed" 2>/dev/null || git init -q "$tmp/seed"
(cd "$tmp/seed" && git config user.email test@kiwami && git config user.name test \
    && mkdir -p hosts/foo && echo 'v1' > hosts/foo/default.nix \
    && git add -A && git commit -qm init \
    && git branch -M main && git push -q "$tmp/origin.git" main)

# Shallow and single-branch, the way `kiwami install` clones. An ordinary
# clone has refs/remotes/origin/* for every branch; this one has main and
# nothing else, which is what broke the second push on the real machine while
# the test was passing against a full clone.
git clone -q --depth 1 --single-branch --branch main "file://$tmp/origin.git" "$tmp/repo"
cd "$tmp/repo"
git config user.email test@kiwami && git config user.name test

# The thing that must not be pushed: a real commit on the local branch, of the
# kind that accumulates in a working tree between one host change and the next.
echo 'do not push me' > unrelated.txt
git add -A && git commit -qm "unrelated local work"
# And a host change that should be pushed.
echo 'v2' > hosts/foo/default.nix

cyan "==> kiwami host push"
KIWAMI_REPO="$PWD" "$kiwami" host push foo --no-pr >/dev/null

cyan "==> what landed"
# Inspected on the remote itself: a single-branch clone has no
# refs/remotes/origin/host/foo to look at, which is the whole point.
bare="$tmp/origin.git"
commits=$(git --git-dir="$bare" rev-list --count main..host/foo)
[ "$commits" = "1" ] || fail "expected 1 commit on the branch, got $commits"
pass "the branch is one commit on top of origin/main"

touched=$(git --git-dir="$bare" diff --name-only main host/foo)
[ "$touched" = "hosts/foo/default.nix" ] || fail "touched more than the host: $touched"
pass "it touches only the host directory"

if git --git-dir="$bare" cat-file -e host/foo:unrelated.txt 2>/dev/null; then
    fail "unrelated local work was pushed"
fi
pass "unrelated local work did not ride along"

# The command must not disturb what the user was doing: no checkout, no stash,
# no commit of their staged work.
head_after=$(git rev-parse --abbrev-ref HEAD)
[ "$head_after" = "main" ] || fail "left the repository on $head_after"
grep -q 'v2' hosts/foo/default.nix || fail "the working tree was modified"
if git worktree list | grep -q kiwami-host; then fail "left a worktree behind"; fi
pass "the working tree, branch and index are untouched"

cyan "==> pushing again with nothing changed"
out=$(KIWAMI_REPO="$PWD" "$kiwami" host push foo --no-pr 2>&1)
# The branch already matches, so this is a no-op rather than an empty commit.
echo "$out" | grep -q "already has exactly this" || fail "expected a no-op, got: $out"
pass "a second push with no change does nothing"

cyan "==> main advances, with the host untouched"
# The real machine hit this and the test did not: the branch was built on an
# older main, so comparing whole trees called it different and re-pushed - and
# then failed the lease. Unrelated progress on main must not make an untouched
# host look changed.
(cd "$tmp/seed" && echo 'unrelated progress' > elsewhere.txt \
    && git add -A && git commit -qm "work on main" && git push -q "$bare" main)

cyan "==> a third run, after the branch exists on the remote"
# This is where the machine failed while the test passed: with a single-branch
# clone there is no refs/remotes/origin/host/foo, so the no-op check could not
# fire and --force-with-lease had no lease - "stale info", every time.
out=$(KIWAMI_REPO="$PWD" "$kiwami" host push foo --no-pr 2>&1)
echo "$out" | grep -q "already has exactly this" || fail "expected a no-op, got: $out"
pass "still a no-op on a shallow clone, with main moved on"

printf '\033[1;32m==> host push sends only the host\033[0m\n'
