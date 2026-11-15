#!/usr/bin/env bash
# penguincam README rule check. Usage: readme-check.sh [--profile] [README.md]
#
# Exits 0 when the file follows the README rule in CONTRIBUTING.md, section
# "README rule". Prints one line per finding and exits 1 otherwise.
# With --profile the file is an organization profile page. It may leave out
# the title and any section, and the sections it has keep the fixed order.
# Plain bash, grep, sed and awk, compatible with bash 3.2.
set -u

profile=0
if [ "${1:-}" = "--profile" ]; then
  profile=1
  shift
fi
file="${1:-README.md}"
max_lines="${PENGUINCAM_README_MAX_LINES:-40}"
want="Start|Tasks|Related|Contributing|License"

if [ ! -f "$file" ]; then
  printf 'readme-check: %s: no such file\n' "$file" >&2
  exit 1
fi

findings=0
fail() {
  printf 'readme-check: %s: %s\n' "$file" "$1" >&2
  findings=$((findings + 1))
}

lines="$(awk 'END { print NR }' "$file")"
if [ "$lines" -gt "$max_lines" ]; then
  fail "$lines lines; the limit is $max_lines"
fi

# Prose outside fenced code blocks, with inline code removed.
# shellcheck disable=SC2016 # the backticks are literal
prose="$(awk '/^[[:space:]]*(```|~~~)/ { fence = !fence; next } !fence' "$file" | sed 's/`[^`]*`//g')"

titles="$(printf '%s\n' "$prose" | grep -c '^# ')"
got="$(printf '%s\n' "$prose" | sed -n 's/^## *//p' | sed 's/[[:space:]]*$//' | paste -sd '|' -)"
if [ "$profile" -eq 1 ]; then
  if [ "$titles" -gt 1 ]; then
    fail "at most one '# ' title is allowed on a profile page"
  fi
  # Each section must be one of the fixed names, after the one before it.
  rest="$want|"
  in_order=1
  sections="$(printf '%s\n' "$got" | tr '|' '\n')"
  while IFS= read -r section; do
    [ -n "$section" ] || continue
    case "$rest" in
      "$section|"*) rest="${rest#"$section|"}" ;;
      *"|$section|"*) rest="${rest#*"|$section|"}" ;;
      *) in_order=0 ;;
    esac
  done <<< "$sections"
  if [ "$in_order" -ne 1 ]; then
    fail "profile sections must come from '## ' $(printf '%s' "$want" | sed 's/|/, /g') and keep that order; found: ${got:-none}"
  fi
else
  first="$(printf '%s\n' "$prose" | sed -n '/[^[:space:]]/{p;q;}')"
  case "$first" in
    "# "?*) ;;
    *) fail "the first line must be the title, written as '# Name'" ;;
  esac

  if [ "$titles" -ne 1 ]; then
    fail "exactly one '# ' title is allowed"
  fi

  if [ "$got" != "$want" ]; then
    fail "sections must be exactly '## ' $(printf '%s' "$want" | sed 's/|/, /g') in that order; found: ${got:-none}"
  fi
fi

if printf '%s\n' "$prose" | grep -qE '^#{3,} '; then
  fail "no headings below '## ' are allowed"
fi

# Ticket ids such as ABC-123, and issue or pull request numbers such as #12.
# Standards that look the same are allowed.
ids="$(grep -oE '(^|[^A-Za-z0-9_-])[A-Z][A-Z0-9]{1,9}-[0-9]{2,}' "$file" | sed 's/^[^A-Z]//' |
  grep -vE '^(SHA|AES|UTF|ISO|IEC|RFC|CVE|ECMA)-' || true)"
if [ -n "$ids" ]; then
  fail "ticket ids are not allowed: $(printf '%s\n' "$ids" | sort -u | tr '\n' ' ')"
fi
if printf '%s\n' "$prose" | grep -qE '(^|[[:space:](])#[0-9]+([^0-9]|$)'; then
  fail "issue or pull request numbers are not allowed"
fi
if grep -qiE '(linear\.app|atlassian\.net|/browse/[A-Z]+-[0-9])' "$file"; then
  fail "links to a ticket tracker are not allowed"
fi

# People: no mail addresses and no @handles.
if grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$file"; then
  fail "mail addresses are not allowed"
fi
if printf '%s\n' "$prose" | grep -qE '(^|[[:space:](])@[A-Za-z0-9][A-Za-z0-9-]*'; then
  fail "@handles are not allowed; name a role instead"
fi

[ "$findings" -eq 0 ]
