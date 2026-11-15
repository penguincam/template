#!/usr/bin/env bash
# Repository contract test. Usage: tests/contract-test.sh [MIRROR]
#
# MIRROR is the organization hook copy: a local directory or a URL. The
# default is the githooks/ directory of penguincam/.github on GitHub.
# Proves that README.md passes the README rule, that the rule check still
# rejects a broken README, that .githooks equals the organization copy, that
# no agent file is tracked and that CODEOWNERS names handles only.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
mirror="${1:-https://raw.githubusercontent.com/penguincam/.github/main/githooks}"
hook_files="_lib.sh commit-msg pre-commit pre-push readme-check.sh test.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/penguincam-contract.XXXXXX")"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
pass() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; }

# README rule
if bash .githooks/readme-check.sh README.md > "$work/out" 2>&1; then
  pass "README.md passes the README rule"
else
  fail "README.md breaks the README rule"
  sed 's/^/     | /' "$work/out"
fi
sed 's/^## Related$/## Notes/' README.md > "$work/broken.md"
if bash .githooks/readme-check.sh "$work/broken.md" > /dev/null 2>&1; then
  fail "the README rule check accepts a README with a renamed section"
else
  pass "the README rule check rejects a README with a renamed section"
fi

# Hooks equal the organization copy
for f in $hook_files; do
  if [ -d "$mirror" ]; then
    cp "$mirror/$f" "$work/$f" 2>/dev/null || : > "$work/$f.missing"
  else
    curl -fsSL "$mirror/$f" -o "$work/$f" 2>/dev/null || : > "$work/$f.missing"
  fi
  if [ -e "$work/$f.missing" ]; then
    fail ".githooks/$f: the organization copy could not be read from $mirror"
  elif cmp -s "$work/$f" ".githooks/$f"; then
    pass ".githooks/$f equals the organization copy"
  else
    fail ".githooks/$f differs from the organization copy"
  fi
done
extra=""
for p in .githooks/* .githooks/.[!.]*; do
  [ -e "$p" ] || continue
  case " $hook_files " in
    *" ${p#.githooks/} "*) ;;
    *) extra="$extra ${p#.githooks/}" ;;
  esac
done
if [ -z "$extra" ]; then
  pass ".githooks holds only the organization files"
else
  fail ".githooks holds extra files: $extra"
fi
for f in commit-msg pre-commit pre-push; do
  if [ -x ".githooks/$f" ]; then pass ".githooks/$f is executable"; else fail ".githooks/$f is not executable"; fi
done

# No agent files
# shellcheck source=../.githooks/_lib.sh
. .githooks/_lib.sh
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  agent="$(git -c core.quotePath=false ls-files | pc_agent_paths)"
else
  agent="$(find . -path ./.git -prune -o -print | sed 's|^\./||' | pc_agent_paths)"
fi
if [ -z "$agent" ]; then
  pass "no agent file is tracked"
else
  fail "agent files are tracked: $(printf '%s\n' "$agent" | tr '\n' ' ')"
fi

# CODEOWNERS
if [ -f .github/CODEOWNERS ] &&
  ! grep -vE '^[[:space:]]*(#.*)?$' .github/CODEOWNERS | grep -qvE '^[^[:space:]]+([[:space:]]+@[A-Za-z0-9][A-Za-z0-9-]*(/[A-Za-z0-9._-]+)?)+[[:space:]]*$'; then
  pass "CODEOWNERS names owners by GitHub handle only"
else
  fail "CODEOWNERS is missing or names an owner other than by handle"
fi

printf '\ncontract-test: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
