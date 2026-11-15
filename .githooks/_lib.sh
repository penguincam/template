# shellcheck shell=bash
# shellcheck disable=SC2034 # variables are used by the hooks that source this file
# Shared helpers for the penguincam git hooks.
#
# Canonical copy: githooks/ in the penguincam/.github repository. Every
# repository carries a byte-identical copy in .githooks/, and
# `just hooks-check` compares that copy with the canonical one.
#
# Plain bash and git only, compatible with bash 3.2. Every refusal or warning
# prints three lines: what happened, the CONTRIBUTING.md section that explains
# the rule, and a command that fixes it.

PC_ORG="penguincam"
PC_CONTRIBUTING="https://github.com/penguincam/.github/blob/main/CONTRIBUTING.md"

# Matches a remote URL that points at a repository of the organization.
PC_ORG_REMOTE_RE='github\.com[:/]+penguincam/'

# Matches a path that is an agent file or lies inside an agent directory.
# Matched without regard to case.
PC_AGENT_PATH_RE='(^|/)(agents\.md|claude\.md|claude\.local\.md|gemini\.md|\.cursorrules|\.windsurfrules|llms\.txt|copilot-instructions\.md)$|(^|/)(\.claude|\.agents|\.codex|\.cursor|\.gemini|\.windsurf|agent-notes)(/|$)'

# The one branch that may carry agent files, and only on a fork.
PC_OVERLAY_BRANCH="agents-overlay"

# Characters built from bytes so these sources contain none of them.
PC_EM_DASH="$(printf '\342\200\224')"
PC_ROBOT="$(printf '\360\237\244\226')"

PC_REFUSED=0

pc_refuse() {
  # $1 what was refused, $2 CONTRIBUTING.md section, $3 fix command
  printf 'penguincam-hooks: REFUSED: %s\n' "$1" >&2
  printf 'penguincam-hooks:   rule: CONTRIBUTING.md, section "%s" (%s)\n' "$2" "$PC_CONTRIBUTING" >&2
  printf 'penguincam-hooks:   fix:  %s\n' "$3" >&2
  PC_REFUSED=1
}

pc_warn() {
  # $1 what looks wrong, $2 CONTRIBUTING.md section, $3 fix command
  printf 'penguincam-hooks: warning: %s\n' "$1" >&2
  printf 'penguincam-hooks:   rule: CONTRIBUTING.md, section "%s" (%s)\n' "$2" "$PC_CONTRIBUTING" >&2
  printf 'penguincam-hooks:   fix:  %s\n' "$3" >&2
}

# Print the message body without comment lines and without anything below a
# `git commit --verbose` scissors line.
pc_message_text() {
  sed -e '/^# -\{1,\} >8 -\{1,\}$/,$d' -e '/^#/d' "$1"
}

# Exit 0 when the message text on stdin carries AI attribution, printing the
# offending line. Co-Authored-By trailers for people pass.
pc_ai_attribution_line() {
  local text first
  text="$(cat)"
  first="$(printf '%s\n' "$text" | sed -n '/[^[:space:]]/{p;q;}')"
  if printf '%s\n' "$first" | grep -iqE '^[[:space:]]*\[codex\]'; then
    printf '%s\n' "$first"
    return 0
  fi
  printf '%s\n' "$text" | grep -m1 -iE '^[[:space:]]*co-authored-by:.*(claude|codex|copilot|gpt|gemini|anthropic\.com|openai\.com)' && return 0
  printf '%s\n' "$text" | grep -m1 -E '^[[:space:]]*[Cc][Oo]-[Aa][Uu][Tt][Hh][Oo][Rr][Ee][Dd]-[Bb][Yy]:(.*[^[:alnum:]])?AI([^[:alnum:]]|$)' && return 0
  printf '%s\n' "$text" | grep -m1 -iE 'generated with' && return 0
  printf '%s\n' "$text" | grep -m1 -F "$PC_ROBOT" && return 0
  return 1
}

# Print each path on stdin that is an agent path, once. Always exits 0.
pc_agent_paths() {
  { grep -iE "$PC_AGENT_PATH_RE" || true; } | sort -u
}

# Run the hook of the same name from the global core.hooksPath, when one is
# set, executable, and a different directory, so a machine-wide hook layer
# keeps running. Never chains twice and never chains to itself.
# $1 hook name, $2 file holding the stdin to replay (or empty), rest: args.
pc_chain() {
  local hook="$1" input="$2" global here there
  shift 2
  [ -z "${PENGUINCAM_HOOKS_CHAINED:-}" ] || return 0
  global="$(git config --global --type=path --get core.hooksPath 2>/dev/null || true)"
  [ -n "$global" ] || return 0
  here="$(cd "$(dirname "$0")" && pwd -P)" || return 0
  there="$(cd "$global" 2>/dev/null && pwd -P)" || return 0
  [ "$here" != "$there" ] || return 0
  [ -f "$there/$hook" ] && [ -x "$there/$hook" ] || return 0
  export PENGUINCAM_HOOKS_CHAINED=1
  if [ -n "$input" ]; then
    "$there/$hook" "$@" < "$input"
  else
    "$there/$hook" "$@"
  fi
}
