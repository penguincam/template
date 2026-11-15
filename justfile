# Recipes shared by every penguincam repository. `just` lists them.

org := "penguincam"
# Set to this repository's name when the template is stamped.
repo := "template"
upstream_repo := org + "/" + repo
hook_files := "_lib.sh commit-msg pre-commit pre-push readme-check.sh test.sh"
hooks_mirror := "https://raw.githubusercontent.com/penguincam/.github/main/githooks"

default:
    @just --list

# Set remotes: origin = your fork <repo>-contrib, the only push target; upstream = penguincam, push off.
fork-setup fork_owner fork_repo=(repo + "-contrib"):
    #!/usr/bin/env bash
    set -euo pipefail
    upstream_url="https://github.com/{{ upstream_repo }}.git"
    fork_url="https://github.com/{{ fork_owner }}/{{ fork_repo }}.git"
    if command -v gh >/dev/null 2>&1; then
      parent="$(gh api "repos/{{ fork_owner }}/{{ fork_repo }}" --jq '.parent.full_name // ""')"
      if [ "$parent" != "{{ upstream_repo }}" ]; then
        echo "fork-setup: {{ fork_owner }}/{{ fork_repo }} is not a GitHub fork of {{ upstream_repo }} (parent: ${parent:-none})" >&2
        exit 1
      fi
    else
      echo "fork-setup: gh not found, so the fork parent is not checked" >&2
    fi
    if git remote get-url upstream >/dev/null 2>&1; then git remote set-url upstream "$upstream_url"; else git remote add upstream "$upstream_url"; fi
    git remote set-url --push upstream DISABLED
    if git remote get-url origin >/dev/null 2>&1; then git remote set-url origin "$fork_url"; else git remote add origin "$fork_url"; fi
    git config remote.pushDefault origin
    git fetch --quiet upstream
    git fetch --quiet origin
    echo "fork-setup: origin = {{ fork_owner }}/{{ fork_repo }}, upstream = {{ upstream_repo }} with push DISABLED"

# Use .githooks for this clone, push to origin only and keep agent files untracked.
hooks-install:
    #!/usr/bin/env bash
    set -euo pipefail
    git config core.hooksPath .githooks
    git config remote.pushDefault origin
    if git remote get-url upstream >/dev/null 2>&1; then
      git remote set-url --push upstream DISABLED
    fi
    exclude="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
    mkdir -p "$(dirname "$exclude")"
    touch "$exclude"
    marker="# penguincam hooks-install: agent files stay untracked"
    grep -qxF -- "$marker" "$exclude" || printf '%s\n' "$marker" >> "$exclude"
    for e in /AGENTS.md /CLAUDE.md /CLAUDE.local.md /GEMINI.md /llms.txt /.cursorrules /.windsurfrules \
      /.claude/ /.agents/ /.codex/ /.cursor/ /.gemini/ /.windsurf/ agent-notes/; do
      grep -qxF -- "$e" "$exclude" || printf '%s\n' "$e" >> "$exclude"
    done
    if [ "$(git config --get commit.gpgsign || true)" != true ]; then
      echo "hooks-install: warning: commit.gpgsign is not true; see the section \"Set up commit signing\" in the contributing guide" >&2
    fi
    echo "hooks-install: hooks from .githooks, pushes go to origin, agent files excluded in $exclude"

# Fail when .githooks differs from the organization copy. mirror may be a URL or a local directory.
hooks-check mirror=hooks_mirror:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    status=0
    for f in {{ hook_files }}; do
      if [ -d "{{ mirror }}" ]; then
        cp "{{ mirror }}/$f" "$tmp/$f"
      else
        curl -fsSL "{{ mirror }}/$f" -o "$tmp/$f"
      fi
      cmp -s "$tmp/$f" ".githooks/$f" || { echo "hooks-check: .githooks/$f differs from {{ mirror }}" >&2; status=1; }
    done
    extra=""
    for p in .githooks/* .githooks/.[!.]*; do
      [ -e "$p" ] || continue
      case " {{ hook_files }} " in
        *" ${p#.githooks/} "*) ;;
        *) extra="$extra ${p#.githooks/}" ;;
      esac
    done
    if [ -n "$extra" ]; then
      echo "hooks-check: files in .githooks that the organization copy does not have: $extra" >&2
      status=1
    fi
    [ "$status" -eq 0 ] && echo "hooks-check: .githooks matches {{ mirror }}"
    exit "$status"

# Run the hook self-test against a throwaway repository.
hooks-test:
    bash .githooks/test.sh

# Check README.md against the README rule.
readme-check:
    bash .githooks/readme-check.sh README.md

# Test the repository contract. Pass a local mirror directory to work offline.
contract-test mirror=hooks_mirror:
    bash tests/contract-test.sh "{{ mirror }}"
