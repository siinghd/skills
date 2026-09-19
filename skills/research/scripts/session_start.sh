#!/usr/bin/env bash
# The session-start ritual, designed to run as a SessionStart hook.
#
# Whatever this prints lands in the agent's context, so it stays bounded: state,
# the recent log, the inbox, live jobs, budget. It must also be harmless in any
# repo that is not a lab, because a hook is configured once and runs everywhere.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: session_start.sh [--help]

Print the session-start briefing for the lab containing the current directory:
STATE.md, the last 3 research-log entries, the inbox, job status, budget and
open questions. Silent (exit 0) outside a lab, so it is safe as a SessionStart
hook in any repo.
USAGE
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

find_lab_root() {
  local d; d="$(pwd -P)"
  while [ "$d" != "/" ]; do
    if [ -f "$d/lab.json" ]; then echo "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

# Not a lab: say nothing at all. A hook that chatters in unrelated repos gets
# disabled, and then it is not there when it matters.
ROOT="$(find_lab_root)" || exit 0

# Sibling scripts, found relative to this file so the bin/ symlink resolves.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== STATE.md =="
if [ -s "$ROOT/STATE.md" ]; then cat "$ROOT/STATE.md"; else echo "(empty)"; fi

echo
echo "== RESEARCH_LOG.md: last 3 entries =="
if [ -s "$ROOT/RESEARCH_LOG.md" ] && grep -q '^### ' "$ROOT/RESEARCH_LOG.md"; then
  # Two passes: count the entries, then print the last 3, each capped at 40 lines.
  # e>0 also guards a log with fewer than 3 entries, where t-3 goes negative and
  # would otherwise let the file's own header through as if it were an entry.
  awk 'NR==FNR { if (/^### /) t++; next }
       /^### / { e++; c=0 }
       e > 0 && e > t-3 { if (c < 40) print; else if (c == 40) print "  [...truncated]"; c++ }' \
    "$ROOT/RESEARCH_LOG.md" "$ROOT/RESEARCH_LOG.md"
else
  echo "(no entries yet)"
fi

echo
echo "== INBOX.md =="
# The header is the H1 plus the standing paragraph explaining what the file is
# for; a real note is anything after that. Detecting it structurally, rather
# than matching the template's wording, survives the human rewriting the blurb.
INBOX_BODY="$(awk '
  BEGIN { state = 0 }
  {
    if (state == 0) {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^#/) { state = 1; next }
      state = 3                              # no heading at all: it is all notes
    }
    if (state == 1) {                        # after the heading, before the blurb
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^#/) next
      state = 2; next
    }
    if (state == 2) {                        # inside the blurb; a blank line ends it
      if ($0 ~ /^[[:space:]]*$/) state = 3
      next
    }
    if ($0 !~ /^[[:space:]]*$/) print
  }' "$ROOT/INBOX.md" 2>/dev/null || true)"
if [ -n "$INBOX_BODY" ]; then
  cat "$ROOT/INBOX.md"
else
  echo "empty"
fi

echo
echo "== JOBS =="
if [ -x "$HERE/collect.sh" ]; then
  (cd "$ROOT" && "$HERE/collect.sh") || echo "(collect.sh failed)"
else
  echo "(collect.sh not found next to session_start.sh)"
fi

echo
echo "== BUDGET =="
if [ -x "$HERE/budget.py" ]; then
  (cd "$ROOT" && "$HERE/budget.py" --brief) || echo "(budget.py failed)"
else
  echo "(budget.py not found next to session_start.sh)"
fi

echo
echo "== QUESTIONS.md =="
if [ -s "$ROOT/QUESTIONS.md" ]; then
  # grep -c exits 1 on zero matches, which set -e would treat as fatal.
  OPEN="$(grep -c '^- \[ \]' "$ROOT/QUESTIONS.md" 2>/dev/null || true)"
  OPEN="${OPEN:-0}"
  if [ "$OPEN" -gt 0 ]; then
    echo "$OPEN open question(s) for the human"
  else
    echo "$(wc -l < "$ROOT/QUESTIONS.md" | tr -d ' ') line(s), no '- [ ]' items"
  fi
else
  echo "(empty)"
fi

echo
echo "Ritual: read FINDINGS.md fully before proposing anything."
