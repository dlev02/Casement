#!/bin/bash
# Repo rules a script can check. The judgement calls are in CODING_STANDARDS.md.
#
#   scripts/lint.sh                 tracked files in the working tree (check.sh and CI)
#   scripts/lint.sh --cached        what's staged (the pre-commit hook)
#   scripts/lint.sh --commits A..B  messages and added lines of those commits (pre-push, CI)
#
# A line that must break a rule on purpose can carry the marker `lint:allow`.
set -euo pipefail
cd "$(dirname "$0")/.."

mode=files
range=
case "${1:-}" in
  --cached) mode=cached ;;
  --commits) mode=commits; range="${2:?--commits needs a range, e.g. origin/main..HEAD}" ;;
  "") ;;
  *) echo "usage: scripts/lint.sh [--cached | --commits A..B]" >&2; exit 2 ;;
esac

failures=0
report() { # rule, matches
  [ -z "$2" ] && return 0
  failures=$((failures + 1))
  printf '\n✗ %s\n%s\n' "$1" "$(printf '%s\n' "$2" | head -20)"
}

# Drops allowed lines and lines that are only a code comment ("// …", "/// …", "# …").
code_only() { grep -v 'lint:allow' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|#)' || true; }
allowed() { grep -v 'lint:allow' || true; }

# --- Nothing personal (CLAUDE.md, "Nothing personal in tracked files") --------------------
# Placeholders: tail1234.ts.net, example.ts.net, 100.64.0.x, fd7a:115c:a1e0::x, you@your-pc.
TS_IPV4='(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}($|[^0-9])'
# The range's own edges (tests of the listener's filter) and MagicDNS's fixed address aren't anyone's.
TS_IPV4_OK='100\.64\.0\.|100\.100\.100\.100|100\.127\.255\.25[45]'
TS_IPV6='fd7a:115c:a1e0:[0-9a-fA-F]{1,4}:[0-9a-fA-F]{1,4}'
TAILNET='[A-Za-z0-9-]+\.ts\.net'
TAILNET_OK='(tail1234|example|tailnet|studio|mullvad)\.ts\.net'
EMAIL='[A-Za-z0-9._%+-]+@(gmail|googlemail|icloud|me|mac|outlook|hotmail|live|yahoo|proton|protonmail)\.(com|me)'

personal_in_lines() { # stdin: "where:line:text" lines
  local lines; lines="$(cat)"
  report "A Tailscale IPv4 address (use 100.64.0.x)" \
    "$(printf '%s\n' "$lines" | grep -E "$TS_IPV4" | grep -vE "$TS_IPV4_OK" | allowed)"
  report "A Tailscale IPv6 address (use fd7a:115c:a1e0::x)" \
    "$(printf '%s\n' "$lines" | grep -E "$TS_IPV6" | allowed)"
  report "A tailnet name (use tail1234.ts.net or example.ts.net)" \
    "$(printf '%s\n' "$lines" | grep -E "$TAILNET" | allowed | while IFS= read -r line; do
         names="$(grep -oE "$TAILNET" <<< "$line")"
         grep -qvE "^$TAILNET_OK\$" <<< "$names" && printf '%s\n' "$line"
       done || true)"
  report "A personal email address (use you@your-pc)" \
    "$(printf '%s\n' "$lines" | grep -E "$EMAIL" | allowed)"
}

grep_files() { # pattern, pathspecs…
  local pattern="$1"; shift
  if [ "$mode" = cached ]; then git grep --cached -nIE "$pattern" -- "$@" || true
  else git grep -nIE "$pattern" -- "$@" || true; fi
}

if [ "$mode" != commits ]; then
  # Personal data, anywhere tracked (this script names the patterns, so skip it).
  everything="$(grep_files '100\.|fd7a:|\.ts\.net|@' . ':!scripts/lint.sh')"
  personal_in_lines <<< "$everything"

  # --- Code rules (docs/guide/*.md say why) --------------------------------------------
  app_swift=('Vantage/*.swift' 'VantageHost/*.swift' 'Shared/*.swift' 'VantageWidgets/*.swift' 'Packages/VantageCore/Sources/*.swift')

  report "Pointer lock is off on purpose (docs/guide/input.md)" \
    "$(grep_files 'prefersPointerLocked[[:space:]]*(:[^=]*)?=[[:space:]]*true|prefersPointerLocked:[[:space:]]*Bool[[:space:]]*\{[[:space:]]*true' "${app_swift[@]}" | code_only)"
  report "MessageChannel must read with minimumIncompleteLength: 1 (CLAUDE.md, Transport)" \
    "$(grep_files 'minimumIncompleteLength:[[:space:]]*[^1 ]|minimumIncompleteLength:[[:space:]]*1[0-9]' 'Packages/VantageCore/Sources/VantageCore/Transport/*.swift' | code_only)"
  report "Never run tccutil from the app (docs/guide/mac-host.md, setup window)" \
    "$(grep_files 'tccutil' "${app_swift[@]}" | code_only)"
  report "Never change a Keychain item's access rules: kSecAttrAccess raises a system dialog (CLAUDE.md)" \
    "$(grep_files 'kSecAttrAccess([^iC]|$)' "${app_swift[@]}" | code_only)"
  report "The donation link lives only on GitHub: App Review 3.1.1 (docs/guide/releases.md)" \
    "$(grep_files '[Kk]o-?[Ff]i' Vantage VantageHost Shared VantageWidgets docs/app-store/metadata docs/app-store/review-notes.txt | allowed)"
  report "Log through os.Logger, not print (shared guide: diagnostics)" \
    "$(grep_files '^[[:space:]]*(print|debugPrint|NSLog)\(' "${app_swift[@]}" | allowed)"
  report "The client never calls Host.current(): it can block on DNS (docs/guide/mac-client.md)" \
    "$(grep_files 'Host\.current\(\)' 'Vantage/*.swift' 'Shared/*.swift' | code_only)"
  report "Log through ILogger, not the console, in the Windows host's libraries and app" \
    "$(grep_files '^[[:space:]]*Console\.(Write|Error)' 'WindowsHost/src/*.cs' ':!WindowsHost/src/Vantage.SyntheticHost' ':!WindowsHost/src/Vantage.Host.Windows.Cli' | allowed)"
else
  # --- Commits: messages and the lines they add ------------------------------------------
  messages="$(git log --format='%h %B' "$range")"
  report "No AI attribution in commit messages (CLAUDE.md, \"Never name Claude\")" \
    "$(printf '%s\n' "$messages" | grep -inE 'co-authored-by|generated (with|by)|claude|anthropic' | allowed)"
  added="$(git log -p --no-merges --format='commit %h' "$range" -- . ':!scripts/lint.sh' \
    | awk '/^commit /{c=$2} /^\+\+\+ /{f=substr($0,7)} /^\+[^+]/{print c " " f ": " substr($0,2)}')"
  personal_in_lines <<< "$added"
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%d rule(s) broken. Fix them, or mark a deliberate line with lint:allow.\n' "$failures" >&2
  exit 1
fi
echo "lint: ok ($mode${range:+ $range})"
