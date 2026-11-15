#!/usr/bin/env bash
# Self-test for the penguincam git hooks and the README rule check.
# Run by `just hooks-test`.
#
# Every fixture commit carries a Signed-off-by line unless a case is about
# a missing one, so each case trips one rule only.
#
# Builds a throwaway repository under ${TMPDIR:-/tmp} with fixture commits,
# pushes to local bare repositories standing in for the organization remote
# and a fork, and asserts exit codes and messages. No key is used: a commit
# counts as signed for the hooks when it carries a gpgsig header, so the test
# writes a placeholder header into the fixtures that need one. GitHub checks
# the real signature. The person's own git configuration is never read: HOME
# and the global config point into the temporary directory, which is removed
# on exit after HOME is restored.
set -euo pipefail

hooks="$(cd "$(dirname "$0")" && pwd -P)"
real_home="${HOME:-}"
work="$(mktemp -d "${TMPDIR:-/tmp}/penguincam-hooks-test.XXXXXX")"
cleanup() {
  export HOME="$real_home"
  rm -rf "$work"
}
trap cleanup EXIT

export HOME="$work/home"
export GIT_CONFIG_GLOBAL="$work/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE SSH_AUTH_SOCK PENGUINCAM_HOOKS_CHAINED PENGUINCAM_HOOKS_ALLOW_ORG_PUSH || true
mkdir -p "$HOME" "$work/marks" "$work/global-hooks"

em="$(printf '\342\200\224')"
robot="$(printf '\360\237\244\226')"

# Vendor and GitHub addresses are assembled at run time so no source line
# carries a literal address. The hooks still see the full address.
ai_vendor_domain=anthropic.com
ai_vendor_alt_domain=openai.com
github_domain=github.com
doc_domain=example.org
claude_addr="noreply@${ai_vendor_domain}"
codex_addr="codex@${ai_vendor_alt_domain}"
github_merge_addr="noreply@${github_domain}"

# A stand-in for a machine-wide hook layer; records that it was chained to.
for hook in pre-commit commit-msg; do
  printf '#!/usr/bin/env bash\n: > "%s/%s"\n' "$work/marks" "$hook" > "$work/global-hooks/$hook"
done
printf '#!/usr/bin/env bash\ncat > "%s/pre-push"\n' "$work/marks" > "$work/global-hooks/pre-push"
chmod +x "$work/global-hooks/"*

git config --global user.name "Hook Test"
git config --global user.email "hook-test@${doc_domain}"
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global core.hooksPath "$work/global-hooks"

passed=0
failed=0
out="$work/out"

# check NAME WANT_STATUS [--warns|--quiet|--refused] -- COMMAND...
check() {
  local name="$1" want="$2" expect="$3" got
  shift 4
  set +e
  "$@" > "$out" 2>&1
  got=$?
  set -e
  local ok=1
  if [ "$want" = 0 ] && [ "$got" -ne 0 ]; then ok=0; fi
  if [ "$want" != 0 ] && [ "$got" -eq 0 ]; then ok=0; fi
  case "$expect" in
    --warns) grep -q '^penguincam-hooks: warning:' "$out" || ok=0 ;;
    --quiet) grep -q '^penguincam-hooks:' "$out" && ok=0 ;;
    --refused) grep -q '^penguincam-hooks: REFUSED:' "$out" && grep -q '^penguincam-hooks:   fix:' "$out" || ok=0 ;;
    --any) ;;
  esac
  if [ "$ok" -eq 1 ]; then
    passed=$((passed + 1))
    printf 'ok   %s\n' "$name"
  else
    failed=$((failed + 1))
    printf 'FAIL %s (exit %s, wanted %s, %s)\n' "$name" "$got" "$want" "$expect"
    sed 's/^/     | /' "$out"
  fi
}

pass() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; }

mark_check() {
  if [ -f "$work/marks/$2" ]; then pass "$1"; else fail "$1 (global $2 hook did not run)"; fi
}

out_has() {
  if grep -qF -- "$2" "$out"; then pass "$1"; else fail "$1"; sed 's/^/     | /' "$out"; fi
}

# Rewrite HEAD with a placeholder gpgsig header. The hooks look for the
# header; they do not verify signatures.
sign_head() {
  local raw new
  raw="$(git cat-file commit HEAD)"
  new="$(printf '%s\n' "$raw" | awk '
    !done && /^committer / { print; print "gpgsig -----BEGIN SSH SIGNATURE-----"; print " placeholder"; print " -----END SSH SIGNATURE-----"; done = 1; next }
    { print }' | git hash-object -t commit -w --stdin)"
  git update-ref HEAD "$new"
}

# A signed and signed-off commit through the hooks; fails when a hook refuses.
commit() { git commit -q --allow-empty -s "$@" && sign_head; }
# An unsigned but signed-off commit that skips the commit hooks.
commit_raw() { git commit -q --allow-empty --no-verify -s "$@"; }
# An unsigned commit with no sign-off that skips the commit hooks.
commit_no_signoff() { git commit -q --allow-empty --no-verify "$@"; }

repo="$work/repo"
git init -q "$repo"
cd "$repo"
git config core.hooksPath "$hooks"

# commit-msg and pre-commit
printf 'plain text\n' > a.txt
git add a.txt
check "conventional commit passes quietly" 0 --quiet -- commit -m "feat: add a"
mark_check "commit-msg chains to the global hooks path" commit-msg
mark_check "pre-commit chains to the global hooks path" pre-commit
base="$(git rev-parse HEAD)"

check "human Co-Authored-By trailer passes" 0 --quiet -- \
  commit -m "docs: pair work" -m "Co-Authored-By: Pat Example <pat@${doc_domain}>"
check "human named Aiden passes" 0 --quiet -- \
  commit -m "docs: pair work" -m "Co-Authored-By: Aiden Example <aiden@${doc_domain}>"
check "Claude trailer refused" 1 --refused -- \
  commit -m "feat: x" -m "Co-Authored-By: Claude <${claude_addr}>"
check "Codex trailer refused" 1 --refused -- \
  commit -m "feat: x" -m "Co-authored-by: Codex <${codex_addr}>"
check "Copilot trailer refused" 1 --refused -- \
  commit -m "feat: x" -m "Co-Authored-By: Copilot <copilot@${doc_domain}>"
check "an AI trailer refused" 1 --refused -- \
  commit -m "feat: x" -m "Co-Authored-By: Some AI <bot@${doc_domain}>"
check "Gemini trailer refused" 1 --refused -- \
  commit -m "feat: x" -m "Co-Authored-By: Gemini <bot@${doc_domain}>"
check "GPT trailer refused" 1 --refused -- \
  commit -m "feat: x" -m "Co-Authored-By: ChatGPT <bot@${doc_domain}>"
check "Generated with line refused" 1 --refused -- \
  commit -m "feat: x" -m "Generated with some tool"
check "robot face refused" 1 --refused -- \
  commit -m "feat: x" -m "$robot made this"
check "[codex] subject prefix refused" 1 --refused -- \
  commit -m "[codex] feat: x"
check "non-conventional subject warns" 0 --warns -- commit -m "update stuff"

# Sign-off
check "commit with no Signed-off-by line refused" 1 --refused -- \
  git commit -q --allow-empty -m "feat: no sign-off"
out_has "sign-off refusal names the Sign off section" 'Sign off every commit'
out_has "sign-off refusal gives the command" 'git commit -S -s'
check "Signed-off-by with no address refused" 1 --refused -- \
  git commit -q --allow-empty -m "feat: x" -m "Signed-off-by: Hook Test"
check "Signed-off-by in the subject only refused" 1 --refused -- \
  git commit -q --allow-empty -m "feat: mention Signed-off-by in prose"
check "Signed-off-by written by hand passes" 0 --quiet -- \
  git commit -q --allow-empty -m "feat: x" -m "Signed-off-by: Pat Example <pat@${doc_domain}>"
check "lower-case signed-off-by passes" 0 --quiet -- \
  git commit -q --allow-empty -m "feat: x" -m "signed-off-by: Pat Example <pat@${doc_domain}>"
check "Signed-off-by in a comment line does not count" 1 --refused -- \
  git commit -q --allow-empty --cleanup=verbatim -m "feat: x" -m "# Signed-off-by: Pat Example <pat@${doc_domain}>"
check "em dash in message warns" 0 --warns -- commit -m "fix: one ${em} two"

printf 'new %s dash\n' "$em" > dash.txt
git add dash.txt
check "em dash added to a new file warns" 0 --warns -- commit -m "docs: add dash file"
printf 'more %s dash\n' "$em" >> dash.txt
git add dash.txt
check "em dash added to a file that had one is quiet" 0 --quiet -- commit -m "docs: extend dash file"

printf 'x\n' > AGENTS.md
git add AGENTS.md
check "agent file staged warns" 0 --warns -- commit -m "chore: stage an agent file"
out_has "agent warning names the Agent files section" 'Agent files'
git rm -q --cached AGENTS.md
rm -f AGENTS.md
commit -m "chore: drop the agent file"

# Loop guard: a global hooks path equal to this directory is never chained to.
git config --global core.hooksPath "$hooks"
check "global hooks path equal to the repo hooks does not loop" 0 --quiet -- commit -m "chore: loop guard"
git config --global core.hooksPath "$work/global-hooks"

# README rule
good="$work/readme-good.md"
cat > "$good" <<'EOF'
# example

One sentence on what this repository holds.

## Start

```sh
gh repo fork penguincam/example --fork-name example-contrib --clone
cd example-contrib && just fork-setup <your-login> && just hooks-install
```

## Tasks

| Task | Command |
|---|---|
| List recipes | `just` |

## Related

- [.github](https://github.com/penguincam/.github): contributing guide and hooks.

## Contributing

Read the contributing guide. Use SHA-256 and UTF-8 freely.

## License

Apache-2.0, in `LICENSE`.
EOF
check "a README that follows the rule passes" 0 --any -- bash "$hooks/readme-check.sh" "$good"

readme_case() {
  # $1 name, $2 text the finding must contain; the README is $work/readme-case.md
  check "README rule: $1" 1 --any -- bash "$hooks/readme-check.sh" "$work/readme-case.md"
  out_has "README rule: $1 names the finding" "$2"
}
# Each case writes the README first, then checks it in this shell, so the
# counters are not lost in a pipeline subshell.
case_file="$work/readme-case.md"
{ cat "$good"; for i in $(seq 1 20); do printf 'line %s\n' "$i"; done; } > "$case_file"
readme_case "too long refused" "the limit is"
sed '1d' "$good" > "$case_file"
readme_case "missing title refused" "first line must be the title"
{ cat "$good"; printf '# second title\n'; } > "$case_file"
readme_case "second title refused" "exactly one"
sed '/^## Related$/d' "$good" > "$case_file"
readme_case "missing section refused" "sections must be exactly"
sed 's/^## Tasks$/## Usage/' "$good" > "$case_file"
readme_case "renamed section refused" "sections must be exactly"
awk '/^## Start$/ { print "## Tasks"; next } /^## Tasks$/ { print "## Start"; next } { print }' "$good" > "$case_file"
readme_case "sections out of order refused" "sections must be exactly"
awk '{ print } /^## Related$/ { print ""; print "### More" }' "$good" > "$case_file"
readme_case "sub-heading refused" "below"
sed 's/^One sentence.*/Tracks ENG-123./' "$good" > "$case_file"
readme_case "ticket id refused" "ticket ids"
sed 's/^One sentence.*/Closes #12./' "$good" > "$case_file"
readme_case "issue number refused" "issue or pull request numbers"
sed 's|^One sentence.*|See https://linear.app/x/issue/a.|' "$good" > "$case_file"
readme_case "tracker link refused" "ticket tracker"
sed "s/^One sentence.*/Ask someone@${doc_domain}./" "$good" > "$case_file"
readme_case "mail address refused" "mail addresses"
sed 's/^One sentence.*/Ask @somebody./' "$good" > "$case_file"
readme_case "handle refused" "@handles"

cp "$good" README.md
git add README.md
check "a staged README that follows the rule is quiet" 0 --quiet -- commit -m "docs: add readme"
sed 's/^## Related$/## Notes/' "$good" > README.md
git add README.md
check "a staged README that breaks the rule warns" 0 --warns -- commit -m "docs: break readme"
out_has "README warning names the README rule section" 'README rule'

# pre-push
mkdir -p "$work/github.com/penguincam" "$work/github.com/someone"
git init -q --bare "$work/github.com/penguincam/repo.git"
git init -q --bare "$work/github.com/someone/repo-contrib.git"
git remote add upstream "file://$work/github.com/penguincam/repo.git"
git remote add origin "file://$work/github.com/someone/repo-contrib.git"

git switch -q -c feat/ok "$base"
commit -m "feat: signed work"
check "push of signed work to the organization remote refused" 1 --refused -- git push -q upstream feat/ok
out_has "refusal names the Fork first section" 'Fork first'
check "push of signed work to the fork passes quietly" 0 --quiet -- git push -q origin feat/ok
if [ -s "$work/marks/pre-push" ] && grep -q 'refs/heads/feat/ok' "$work/marks/pre-push"; then
  pass "pre-push chains to the global hooks path with stdin"
else
  fail "pre-push chain did not receive stdin"
fi

sha="$(git rev-parse HEAD)"
null="$(printf '%0*d' "${#sha}" 0)"
synthetic() { printf 'refs/heads/feat/ok %s refs/heads/feat/ok %s\n' "$sha" "$null" | "$hooks/pre-push" "$1" "$2"; }
for url in git@github.com:penguincam/repo.git https://github.com/penguincam/repo.git \
  ssh://git@github.com/PenguinCam/repo.git; do
  check "synthetic push to $url refused" 1 --refused -- synthetic upstream "$url"
done
check "synthetic push to a fork URL passes" 0 --quiet -- synthetic origin git@github.com:someone/repo-contrib.git
check "synthetic push to an owner named penguincam-like passes" 0 --quiet -- \
  synthetic origin git@github.com:penguincam-like/repo-contrib.git
check "owner override lets a clean push reach the organization" 0 --quiet -- \
  env PENGUINCAM_HOOKS_ALLOW_ORG_PUSH=1 git push -q upstream feat/ok

git switch -q -c wip/x "$base"
commit -m "feat: signed work on a loose branch"
check "branch wip/x warns but pushes" 0 --warns -- git push -q origin wip/x

git switch -q -c feat/unsigned "$base"
commit_raw -m "feat: unsigned work"
check "unsigned commit refused" 1 --refused -- git push -q origin feat/unsigned
out_has "unsigned refusal gives the rebase command" 'rebase --force-rebase --gpg-sign'
out_has "unsigned refusal says not to rebase upstream commits" 'do not rebase them'

git switch -q -c feat/trailer "$base"
commit_raw -m "feat: trailer" -m "Co-Authored-By: Claude <${claude_addr}>"
sign_head
check "AI trailer committed with --no-verify refused at push" 1 --refused -- git push -q origin feat/trailer
out_has "attribution refusal names the commit" 'carries AI attribution'

git switch -q -c feat/generated "$base"
commit_raw -m "feat: generated" -m "Generated with a tool"
sign_head
check "generated-by line refused at push" 1 --refused -- git push -q origin feat/generated

git switch -q -c feat/no-signoff "$base"
commit_no_signoff -m "feat: signed but not signed off"
sign_head
check "signed commit with no sign-off refused at push" 1 --refused -- git push -q origin feat/no-signoff
out_has "push sign-off refusal names the commit list" 'no Signed-off-by line in the pushed range'
out_has "push sign-off refusal gives the rebase command" 'rebase --force-rebase --signoff --gpg-sign'
out_has "push sign-off refusal says not to rebase upstream commits" 'do not rebase them'
check "owner override still refuses a commit with no sign-off" 1 --refused -- \
  env PENGUINCAM_HOOKS_ALLOW_ORG_PUSH=1 git push -q upstream feat/no-signoff

# Agent files
agent_case() {
  # $1 branch, $2 path to add
  git switch -q -c "$1" "$base"
  mkdir -p "$(dirname "$2")"
  printf 'agent\n' > "$2"
  git add -- "$2"
  commit_raw -m "feat: add $2"
  sign_head
  check "agent path $2 refused at push" 1 --refused -- git push -q origin "$1"
  out_has "agent refusal for $2 names the path" "$2"
}
agent_case feat/agents-md AGENTS.md
agent_case feat/claude-md sub/CLAUDE.md
agent_case feat/claude-dir .claude/settings.json
agent_case feat/notes docs/agent-notes/2026-01-01.md
agent_case feat/cursor .cursorrules

git switch -q -c feat/added-then-removed "$base"
printf 'agent\n' > CLAUDE.md
git add CLAUDE.md
commit_raw -m "feat: add notes"
sign_head
git rm -q CLAUDE.md
commit_raw -m "chore: remove notes"
sign_head
check "agent file added and removed inside the range refused" 1 --refused -- git push -q origin feat/added-then-removed

git switch -q -c feat/lookalike "$base"
printf 'x\n' > agentsmith.md
mkdir -p docs && printf 'x\n' > docs/claude-notes.txt
git add agentsmith.md docs/claude-notes.txt
commit -m "feat: names that only look like agent files"
check "paths that only look like agent files pass" 0 --quiet -- git push -q origin feat/lookalike

check "owner override still refuses agent files" 1 --refused -- \
  env PENGUINCAM_HOOKS_ALLOW_ORG_PUSH=1 git push -q upstream feat/agents-md

git switch -q --orphan agents-overlay
printf 'agent\n' > AGENTS.md
mkdir -p .claude && printf '{}\n' > .claude/settings.json
git add AGENTS.md .claude/settings.json
commit -m "chore(overlay): agent files"
check "agents-overlay branch with agent files passes to the fork" 0 --quiet -- git push -q origin agents-overlay
check "agents-overlay branch refused to the organization even with the override" 1 --refused -- \
  env PENGUINCAM_HOOKS_ALLOW_ORG_PUSH=1 git push -q upstream agents-overlay
check "agent files pushed from another branch name refused" 1 --refused -- git push -q origin agents-overlay:feat/overlay-copy

# Commits already on the destination remote are not walked again. This is
# how upstream history in a fork, unsigned and with no sign-offs, stays out
# of the walk: the fork already holds it.
git switch -q -c feat/legacy "$base"
commit_no_signoff -m "chore: legacy upstream commit, unsigned and not signed off"
git push -q --no-verify origin feat/legacy
git switch -q -c feat/stacked
commit -m "feat: signed on top of legacy"
check "commits already on the destination remote are not walked again" 0 --quiet -- git push -q origin feat/stacked

# An agent file added in a commit the destination already holds is not in
# the walked commits, but it is in the pushed tree.
git switch -q -c feat/held-agent "$base"
printf 'agent\n' > AGENTS.md
git add -f AGENTS.md
commit_raw -m "chore: held agent file"
sign_head
git push -q --no-verify origin feat/held-agent
git switch -q -c feat/held-agent-stacked
commit -m "feat: signed on top of a held agent file"
check "agent file in the pushed tree from a held commit refused" 1 --refused -- git push -q origin feat/held-agent-stacked
git rm -q AGENTS.md
commit -m "chore: drop the held agent file"

# Commits that only another remote holds, such as an archive, are walked
# again for each destination that does not have them.
git init -q --bare "$work/archive.git"
git remote add archive "file://$work/archive.git"
git switch -q -c feat/archived "$base"
printf 'agent\n' > AGENTS.md
git add -f AGENTS.md
commit_raw -m "chore: archived agent file"
sign_head
git rm -q AGENTS.md
commit_raw -m "chore: drop the archived agent file"
sign_head
git push -q --no-verify archive feat/archived
check "agent file in history held only by an archive remote refused at the organization" 1 --refused -- \
  env PENGUINCAM_HOOKS_ALLOW_ORG_PUSH=1 git push -q upstream feat/archived
out_has "archive agent refusal names the path" 'AGENTS.md'
check "agent file in history held only by an archive remote refused at the fork" 1 --refused -- \
  git push -q origin feat/archived
git switch -q -c feat/archived-unsigned "$base"
commit_raw -m "chore: archived unsigned"
git push -q --no-verify archive feat/archived-unsigned
check "unsigned commit held only by an archive remote refused at the organization" 1 --refused -- \
  env PENGUINCAM_HOOKS_ALLOW_ORG_PUSH=1 git push -q upstream feat/archived-unsigned
git switch -q -c feat/archived-trailer "$base"
commit_raw -m "chore: archived trailer" -m "Co-Authored-By: Claude <${claude_addr}>"
sign_head
git push -q --no-verify archive feat/archived-trailer
check "AI attribution held only by an archive remote refused at the organization" 1 --refused -- \
  env PENGUINCAM_HOOKS_ALLOW_ORG_PUSH=1 git push -q upstream feat/archived-trailer
git switch -q -c feat/archived-no-signoff "$base"
commit_no_signoff -m "chore: archived with no sign-off"
sign_head
git push -q --no-verify archive feat/archived-no-signoff
check "commit with no sign-off held only by an archive remote refused at the organization" 1 --refused -- \
  env PENGUINCAM_HOOKS_ALLOW_ORG_PUSH=1 git push -q upstream feat/archived-no-signoff

# Merge commits made by GitHub are exempt from the signature and sign-off
# rules. The merge below carries neither.
git switch -q -c feat/merged "$base"
commit -m "feat: left"
GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL="$github_merge_addr" \
  git merge -q --no-verify --no-ff -m "Merge pull request from someone/feat/ok" feat/ok
check "unsigned GitHub merge commit with no sign-off is exempt" 0 --quiet -- git push -q origin feat/merged

git switch -q -c feat/local-merge "$base"
commit -m "feat: right"
git merge -q --no-verify --no-ff --signoff -m "Merge branch 'feat/ok'" feat/ok
check "unsigned local merge commit refused" 1 --refused -- git push -q origin feat/local-merge
out_has "unsigned local merge refusal names the signature" 'unsigned commits in the pushed range'

git switch -q -c feat/local-merge-no-signoff "$base"
commit -m "feat: right again"
git merge -q --no-verify --no-ff -m "Merge branch 'feat/ok'" feat/ok
sign_head
check "signed local merge commit with no sign-off refused" 1 --refused -- git push -q origin feat/local-merge-no-signoff
out_has "local merge sign-off refusal names the rule" 'no Signed-off-by line'

git switch -q -c feat/github-lookalike-commit "$base"
GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL="$github_merge_addr" \
  commit_no_signoff -m "feat: single-parent commit by GitHub"
sign_head
check "single-parent GitHub commit with no sign-off refused" 1 --refused -- git push -q origin feat/github-lookalike-commit

check "branch deletion passes" 0 --quiet -- git push -q origin :wip/x

# The overlay branch on the fork does not make its commits count as pushed:
# merged into another branch and then removed, the files are still refused.
git switch -q -c feat/overlay-merged "$base"
git merge -q --no-verify --allow-unrelated-histories -m "chore: merge the overlay" agents-overlay
sign_head
git rm -q -r AGENTS.md .claude
commit -m "chore: drop the overlay files"
git branch -q -D agents-overlay
check "overlay merged into a branch and removed refused at the fork" 1 --refused -- \
  git push -q origin feat/overlay-merged
out_has "overlay merge refusal names the path" '.claude/settings.json'
check "overlay merged into a branch and removed refused at the organization" 1 --refused -- \
  env PENGUINCAM_HOOKS_ALLOW_ORG_PUSH=1 git push -q upstream feat/overlay-merged

printf '\nhooks-test: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
