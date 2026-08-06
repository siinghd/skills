#!/usr/bin/env bash
# test-or-evidence.sh — self-test for or-evidence.sh.
#
# Builds throwaway git repos under $(mktemp -d) and proves the eight properties
# the evidence collector exists for. The headline one is case 1: it asserts that
# `git status --porcelain` is BLIND to a destroyed peer file while the evidence
# card catches it — if that assertion ever flips, the whole premise of the tool
# is wrong and this test should fail loudly.
#
# Exits 0 only if every assertion in every case passes.
set -uo pipefail

EV="$(cd "$(dirname "$0")/.." && pwd)/or-evidence.sh"
[ -f "$EV" ] || { echo "cannot find or-evidence.sh at $EV" >&2; exit 1; }

TOTAL_FAILS=0
CASE_NAME=""
CASE_FAILS=0

begin() { CASE_NAME="$1"; CASE_FAILS=0; }
end() {
  if [ "$CASE_FAILS" -eq 0 ]; then
    echo "PASS  $CASE_NAME"
  else
    echo "FAIL  $CASE_NAME  ($CASE_FAILS assertion(s) failed)"
    TOTAL_FAILS=$((TOTAL_FAILS + CASE_FAILS))
  fi
}
bad() { echo "        ✗ $*"; CASE_FAILS=$((CASE_FAILS + 1)); }

assert_eq() { # <what> <actual> <expected>
  [ "$2" = "$3" ] || bad "$1: expected [$3], got [$2]"
}
assert_has() { # <what> <haystack> <needle>
  printf '%s' "$2" | grep -qF -- "$3" || bad "$1: expected output to contain [$3]"
}
assert_not_has() { # <what> <haystack> <needle>
  if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1: output should NOT contain [$3]"; fi
}

# Fresh repo with a base commit; echoes its path.
mkrepo() {
  local d; d="$(mktemp -d)"
  git init -q "$d"
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name "test"
  git -C "$d" config commit.gpgsign false
  mkdir -p "$d/src" "$d/other"
  printf 'peer original\n'   > "$d/src/peer.ts"
  printf 'mine original\n'   > "$d/src/mine.ts"
  printf 'other original\n'  > "$d/other/b.ts"
  git -C "$d" add -A
  git -C "$d" commit -qm base
  printf '%s' "$d"
}

# Run the card, capturing output and exit code without tripping set -e.
card() { # <outvar-unused> ...args -> sets CARD_OUT / CARD_RC
  CARD_RC=0
  CARD_OUT="$("$EV" card "$@" 2>&1)" || CARD_RC=$?
}

echo "or-evidence self-test"
echo

# ---------------------------------------------------------------------------
# 1. THE INCIDENT: a worker destroys a peer's uncommitted work with
#    `git checkout --`, and git status cannot see it.
# ---------------------------------------------------------------------------
begin "1  incident — reverted peer file is invisible to git status, caught by the card"
R="$(mkrepo)"
printf 'PEER COMPLETED WORK\n' > "$R/src/peer.ts"          # peer's unstaged work
PRE="$("$EV" snapshot "$R")"
printf 'mine edited by worker\n' > "$R/src/mine.ts"        # worker's own legit edit
git -C "$R" checkout -- src/peer.ts                        # <-- the destruction
POST="$("$EV" snapshot "$R")"

STATUS="$(git -C "$R" status --porcelain)"
assert_not_has "git status is blind to the destroyed file" "$STATUS" "peer.ts"
assert_has     "git status does see the worker's own edit"  "$STATUS" "mine.ts"

card --dir "$R" --pre "$PRE" --post "$POST"
assert_eq  "exit code is CRITICAL" "$CARD_RC" "2"
assert_has "reverted_paths section present" "$CARD_OUT" "reverted_paths"
assert_has "peer.ts flagged as reverted"    "$CARD_OUT" "src/peer.ts"

# and the worker's own legitimate edit must NOT be flagged as a revert
REV="$("$EV" card --dir "$R" --pre "$PRE" --post "$POST" --json 2>/dev/null | jq -c '.reverted_paths')" || true
assert_eq "only peer.ts is reverted" "$REV" '["src/peer.ts"]'
end

# ---------------------------------------------------------------------------
# 2. Clean legitimate edit: no critical signals, perfect fidelity.
# ---------------------------------------------------------------------------
begin "2  clean edit — exit 0, no reverted/deletions, fidelity 1.00"
R="$(mkrepo)"
PRE="$("$EV" snapshot "$R")"
printf 'mine edited\n' > "$R/src/mine.ts"
POST="$("$EV" snapshot "$R")"
card --dir "$R" --pre "$PRE" --post "$POST" --claimed "src/mine.ts"
assert_eq  "exit code is pass"   "$CARD_RC" "0"
assert_has "fidelity is 1.00"    "$CARD_OUT" "report_fidelity 1.00"
assert_has "verdict PASS"        "$CARD_OUT" "VERDICT: PASS"
J="$("$EV" card --dir "$R" --pre "$PRE" --post "$POST" --claimed "src/mine.ts" --json)" || true
assert_eq "no reverted paths"  "$(printf '%s' "$J" | jq -c '.reverted_paths')" '[]'
assert_eq "no deletions"       "$(printf '%s' "$J" | jq -c '.deletions')"      '[]'
assert_eq "observed is mine.ts" "$(printf '%s' "$J" | jq -c '.observed')"      '["src/mine.ts"]'
end

# ---------------------------------------------------------------------------
# 3. Snapshot purity: the real index and git status must be untouched.
# ---------------------------------------------------------------------------
begin "3  snapshot purity — .git/index byte-identical and git status unchanged"
R="$(mkrepo)"
printf 'dirty\n' > "$R/src/mine.ts"
printf 'untracked\n' > "$R/src/new.ts"
git -C "$R" add src/mine.ts            # leave a STAGED change too, to be thorough
# Settle first: `git status` itself may rewrite the index's stat cache for
# racily-clean entries, and that must not be attributed to snapshot.
git -C "$R" status --porcelain >/dev/null
git -C "$R" status --porcelain >/dev/null
ST_BEFORE="$(git -C "$R" status --porcelain)"
IDX_BEFORE="$(shasum -a 256 < "$R/.git/index")"

_="$("$EV" snapshot "$R")"

IDX_AFTER="$(shasum -a 256 < "$R/.git/index")"
ST_AFTER="$(git -C "$R" status --porcelain)"
assert_eq "the .git/index bytes are unchanged" "$IDX_AFTER" "$IDX_BEFORE"
assert_eq "git status output is unchanged"     "$ST_AFTER"  "$ST_BEFORE"
assert_has "staged change survived"  "$ST_BEFORE" "M  src/mine.ts"
assert_has "untracked file survived" "$ST_BEFORE" "?? src/new.ts"
end

# ---------------------------------------------------------------------------
# 4. Scope violation.
# ---------------------------------------------------------------------------
begin "4  scope violation — edit outside --scope exits 1 and names the path"
R="$(mkrepo)"
PRE="$("$EV" snapshot "$R")"
printf 'mine edited\n' > "$R/src/mine.ts"
printf 'out of scope edit\n' > "$R/other/b.ts"
POST="$("$EV" snapshot "$R")"
card --dir "$R" --pre "$PRE" --post "$POST" --scope 'src/**'
assert_eq  "exit code is FAIL"          "$CARD_RC" "1"
assert_has "out_of_scope section shown" "$CARD_OUT" "out_of_scope"
assert_has "offending path named"       "$CARD_OUT" "other/b.ts"
J="$("$EV" card --dir "$R" --pre "$PRE" --post "$POST" --scope 'src/**' --json)" || true
assert_eq "in-scope file not reported" "$(printf '%s' "$J" | jq -c '.out_of_scope')" '["other/b.ts"]'
# multi-glob form must admit both trees
card --dir "$R" --pre "$PRE" --post "$POST" --scope 'src/**:other/**'
assert_eq "multi-glob scope passes" "$CARD_RC" "0"
end

# ---------------------------------------------------------------------------
# 5. Deletion of a tracked file.
# ---------------------------------------------------------------------------
begin "5  deletion — removing a tracked file exits 2"
R="$(mkrepo)"
PRE="$("$EV" snapshot "$R")"
rm "$R/other/b.ts"
POST="$("$EV" snapshot "$R")"
card --dir "$R" --pre "$PRE" --post "$POST"
assert_eq  "exit code is CRITICAL" "$CARD_RC" "2"
assert_has "deletions section shown" "$CARD_OUT" "deletions"
assert_has "deleted path named"      "$CARD_OUT" "other/b.ts"
J="$("$EV" card --dir "$R" --pre "$PRE" --post "$POST" --json)" || true
assert_eq "deletions list is exact" "$(printf '%s' "$J" | jq -c '.deletions')" '["other/b.ts"]'
end

# ---------------------------------------------------------------------------
# 6. Report fidelity.
# ---------------------------------------------------------------------------
begin "6  fidelity — 5 changed, 2 claimed → 0.40, exit 1"
R="$(mkrepo)"
PRE="$("$EV" snapshot "$R")"
i=1
while [ "$i" -le 5 ]; do
  printf 'changed %s\n' "$i" > "$R/src/f$i.ts"
  i=$((i + 1))
done
POST="$("$EV" snapshot "$R")"
card --dir "$R" --pre "$PRE" --post "$POST" --claimed "src/f1.ts:src/f2.ts"
assert_eq  "exit code is FAIL"  "$CARD_RC" "1"
assert_has "fidelity is 0.40"   "$CARD_OUT" "report_fidelity 0.40"
J="$("$EV" card --dir "$R" --pre "$PRE" --post "$POST" --claimed "src/f1.ts:src/f2.ts" --json)" || true
# jq preserves the literal "0.40", so compare numerically rather than textually.
assert_eq "json fidelity equals 0.4" "$(printf '%s' "$J" | jq -c '.report_fidelity == 0.4')" 'true'
assert_eq "five files observed"  "$(printf '%s' "$J" | jq -c '.observed | length')" '5'
# absolute claimed paths must normalize to repo-relative, not score 0.00
card --dir "$R" --pre "$PRE" --post "$POST" \
     --claimed "$R/src/f1.ts:$R/src/f2.ts:$R/src/f3.ts:$R/src/f4.ts:$R/src/f5.ts"
assert_eq "absolute claimed paths normalize" "$CARD_RC" "0"
assert_has "full claim scores 1.00" "$CARD_OUT" "report_fidelity 1.00"
end

# ---------------------------------------------------------------------------
# 7. Harness-artifact exclusions.
# ---------------------------------------------------------------------------
begin "7  exclusions — CONTEXT.md / .DS_Store never surface and never break scope"
R="$(mkrepo)"
printf 'ctx v1\n' > "$R/CONTEXT.md"
printf 'ds v1\n'  > "$R/.DS_Store"
printf 'led v1\n' > "$R/.ledger.json"
printf 'orig v1\n' > "$R/src/mine.ts.orig"
git -C "$R" add -A
git -C "$R" commit -qm artifacts
PRE="$("$EV" snapshot "$R")"
printf 'ctx v2\n' > "$R/CONTEXT.md"
printf 'ds v2\n'  > "$R/.DS_Store"
printf 'led v2\n' > "$R/.ledger.json"
printf 'orig v2\n' > "$R/src/mine.ts.orig"
printf 'mine edited\n' > "$R/src/mine.ts"
POST="$("$EV" snapshot "$R")"
card --dir "$R" --pre "$PRE" --post "$POST" --scope 'src/**' --claimed "src/mine.ts"
assert_eq      "exit 0 despite artifact churn" "$CARD_RC" "0"
assert_not_has "CONTEXT.md excluded"  "$CARD_OUT" "CONTEXT.md"
assert_not_has ".DS_Store excluded"   "$CARD_OUT" ".DS_Store"
assert_not_has ".ledger excluded"     "$CARD_OUT" ".ledger"
assert_not_has "*.orig excluded"      "$CARD_OUT" ".orig"
assert_has     "fidelity unaffected"  "$CARD_OUT" "report_fidelity 1.00"
J="$("$EV" card --dir "$R" --pre "$PRE" --post "$POST" --scope 'src/**' --json)" || true
assert_eq "only the real edit is observed" "$(printf '%s' "$J" | jq -c '.observed')" '["src/mine.ts"]'
# artifacts alone must read as a noop, not as changes
printf 'ctx v3\n' > "$R/CONTEXT.md"
POST2="$("$EV" snapshot "$R")"
card --dir "$R" --pre "$POST" --post "$POST2" --scope 'src/**'
assert_eq  "artifact-only run exits 0" "$CARD_RC" "0"
assert_has "and reports zero changes"  "$CARD_OUT" "changed: 0 file(s)"
end

# ---------------------------------------------------------------------------
# 8. Run-log parsing must survive the junk that really lands in these logs.
# ---------------------------------------------------------------------------
begin "8  log parsing — tool_use path extracted, scalar and non-JSON lines survived"
R="$(mkrepo)"
PRE="$("$EV" snapshot "$R")"
printf 'mine edited\n' > "$R/src/mine.ts"
printf 'sneaky\n' > "$R/other/b.ts"     # changed in tree with no tool call
POST="$("$EV" snapshot "$R")"
LOG="$R/run.jsonl"
{
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"s1","model":"m"}'
  printf '%s\n' '42'
  printf '%s\n' 'litellm: WARNING this is not json at all'
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"working\"},{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{\"file_path\":\"$R/src/mine.ts\"}}]}}"
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Write\",\"input\":{\"file_path\":\"$R/src/ghost.ts\"}}]}}"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}'
  printf '%s\n' '"a bare json string"'
  printf '%s\n' '{"type":"result","subtype":"success","total_cost_usd":0.01}'
} > "$LOG"
card --dir "$R" --pre "$PRE" --post "$POST" --log "$LOG"
assert_eq  "log parsing did not crash"   "$CARD_RC" "0"
assert_has "wrote_paths reported"        "$CARD_OUT" "wrote_paths: 2"
J="$("$EV" card --dir "$R" --pre "$PRE" --post "$POST" --log "$LOG" --json)" || true
assert_eq "edited path extracted"     "$(printf '%s' "$J" | jq -c '.wrote_paths')" '["src/mine.ts","src/ghost.ts"]'
assert_eq "ghost write flagged"       "$(printf '%s' "$J" | jq -c '.wrote_not_observed')" '["src/ghost.ts"]'
assert_eq "untool-ed change flagged"  "$(printf '%s' "$J" | jq -c '.observed_not_wrote')" '["other/b.ts"]'
end

# ---------------------------------------------------------------------------
# 9. Noop is a warning, not a failure.
# ---------------------------------------------------------------------------
begin "9  noop — identical snapshots warn but exit 0"
R="$(mkrepo)"
PRE="$("$EV" snapshot "$R")"
POST="$("$EV" snapshot "$R")"
assert_eq "snapshot is deterministic" "$POST" "$PRE"
card --dir "$R" --pre "$PRE" --post "$POST" --claimed "src/mine.ts"
assert_eq  "exit 0"                  "$CARD_RC" "0"
assert_has "noop warned"             "$CARD_OUT" "noop"
assert_has "empty observed → 1.00"   "$CARD_OUT" "report_fidelity 1.00"
end

echo
if [ "$TOTAL_FAILS" -eq 0 ]; then
  echo "ALL CASES PASSED"
  exit 0
fi
echo "$TOTAL_FAILS ASSERTION(S) FAILED"
exit 1
