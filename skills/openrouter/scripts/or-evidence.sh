#!/usr/bin/env bash
# or-evidence.sh — deterministic, git-derived evidence for what an agent run
# ACTUALLY changed. Built to replace two things that do not work: worker
# self-reports (which have been demonstrably false — "no other files touched"
# while three files were modified) and `git status` checks.
#
# Why not `git status`: it is STRUCTURALLY BLIND to the worst failure mode.
# When a worker runs `git checkout -- peer.ts`, a peer's uncommitted work is
# destroyed and the file LEAVES the dirty set, so status reports nothing at all.
# Diffing two working-tree snapshots sees it; status cannot, ever.
#
# Usage:
#   or-evidence.sh snapshot <workdir>
#       Print a tree SHA capturing <workdir>'s current working state (tracked
#       changes + untracked-but-not-ignored files), and nothing else. Read-only
#       with respect to the repo: staging happens in a throwaway index, so the
#       real .git/index and `git status` output are byte-identical afterwards.
#
#   or-evidence.sh card --dir <workdir> --pre <sha> --post <sha>
#                       [--log <run.jsonl>] [--scope 'glob:glob']
#                       [--claimed 'path:path'] [--json]
#       Render an evidence card comparing two snapshots.
#
# Signals (all derived from the tree diff, never from git status):
#   reverted_paths   CRITICAL  post blob == HEAD blob AND pre blob != HEAD blob
#                              — i.e. the run put a file BACK to its committed
#                              state, destroying work that existed at PRE.
#   deletions        CRITICAL  present at PRE, absent at POST, exists at HEAD.
#   out_of_scope     FAIL      changed paths matching no --scope glob.
#   report_fidelity  FAIL<0.50 |claimed ∩ observed| / |observed|.
#   noop             WARN      PRE == POST; the run changed nothing.
#   churn            INFO      added/deleted line counts.
#   wrote_*          INFO      what the run's tool calls claim to have written
#                              vs. what the tree actually shows.
#
# Exit codes: 0 = pass, 1 = a FAIL signal is present, 2 = a CRITICAL signal is
# present (critical wins). Usage/argument errors also exit 2 but print a line
# beginning "ERROR:" on stderr, which is how a harness tells the two apart.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  or-evidence.sh snapshot <workdir>
  or-evidence.sh card --dir <workdir> --pre <sha> --post <sha>
                      [--log <run.jsonl>] [--scope 'glob:glob']
                      [--claimed 'path:path'] [--json]
EOF
}

die() { echo "ERROR: $*" >&2; exit 2; }

# --- path sets -------------------------------------------------------------

# Harness artifacts. These are written by the dispatch machinery, not by the
# work, so they must be filtered out of EVERY path set — otherwise every single
# task reports out-of-scope changes and the signal becomes noise.
is_excluded() {
  local p="$1" base
  case "$p" in
    .git/*|*/.git/*) return 0 ;;
  esac
  base="${p##*/}"
  case "$base" in
    .DS_Store|CONTEXT.md|.mem-drop.ndjson) return 0 ;;
    *.orig|*.rej)                          return 0 ;;
    .ledger*)                              return 0 ;;
  esac
  return 1
}

# Lists are newline-delimited strings (bash 3.2 has no associative arrays and
# no mapfile, so this stays the portable representation throughout).
list_count() {
  [ -n "${1:-}" ] || { echo 0; return 0; }
  printf '%s\n' "$1" | grep -c . || true
}

list_has() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "$1" | grep -qxF "$2"
}

to_json_array() {
  printf '%s' "${1:-}" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

# --- snapshot --------------------------------------------------------------

# Stage the whole working tree into a TEMPORARY index and write it out as a
# tree object. GIT_INDEX_FILE redirects every write away from .git/index, so
# the caller's staged/unstaged state is untouched. New blobs do land in
# .git/objects — that is required for the trees to be diffable later, and it
# changes neither `git status` nor the index.
snap_tree() {
  local dir="$1" idx tree rc=0
  idx="$(mktemp "${TMPDIR:-/tmp}/or-ev-idx.XXXXXX")"
  # mktemp leaves a 0-byte file, which git rejects as a corrupt index on a repo
  # with no commits (read-tree HEAD fails, so nothing ever initialises it).
  # Removing it lets git create a fresh index; the path is still ours.
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$dir" read-tree HEAD 2>/dev/null || true
  GIT_INDEX_FILE="$idx" git -C "$dir" add -A >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$idx" "$idx.lock"
    die "could not stage working tree of $dir (git add -A exited $rc)"
  fi
  tree="$(GIT_INDEX_FILE="$idx" git -C "$dir" write-tree)" || rc=$?
  rm -f "$idx" "$idx.lock"
  [ "$rc" -eq 0 ] || die "could not write tree for $dir"
  printf '%s\n' "$tree"
}

# --- scope globs -----------------------------------------------------------

# Scope patterns are colon-separated and matched with bash [[ == ]] pattern
# matching. Inside [[ ]] bash does NOT special-case "/", so both "*" and "**"
# match across directory separators: 'src/**' matches src/a/b/c.ts, and '*.md'
# matches docs/x.md. Consequence worth knowing: a bare directory name does not
# match its contents — write 'dir/**', not 'dir'.
matches_scope() {
  local p="$1" pat rc=1 reglob=
  # An unquoted word in a `for` list undergoes word-splitting AND pathname
  # expansion. Without `set -f` bash expands 'src/**' against the CURRENT
  # DIRECTORY first, so the pattern list becomes real filenames and the verdict
  # depends on the cwd — the caller cd's into the repo, so it always fired,
  # reporting in-scope work as out_of_scope. Disable globbing for the split
  # only; `[[ == ]]` still pattern-matches because its RHS is unquoted.
  case "$-" in *f*) ;; *) reglob=1 ;; esac
  set -f
  local IFS=':'
  # shellcheck disable=SC2086
  for pat in $SCOPE; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2053
    if [[ "$p" == $pat ]]; then rc=0; break; fi
  done
  [ -z "$reglob" ] || set +f
  return $rc
}

# --- main ------------------------------------------------------------------

case "${1:-}" in
  snapshot)
    DIR="${2:-}"
    [ -n "$DIR" ] || { usage; exit 2; }
    [ -d "$DIR" ] || die "no such directory: $DIR"
    git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $DIR"
    snap_tree "$DIR"
    ;;

  card)
    shift
    DIR="" PRE="" POST="" LOG="" SCOPE="" CLAIMED="" JSON=false
    # Hand-rolled flag loop rather than the getopts the sibling scripts use:
    # the integration contract for this command is long flags, which getopts
    # cannot express.
    while [ $# -gt 0 ]; do
      case "$1" in
        --dir)     DIR="${2:-}";     shift 2 ;;
        --pre)     PRE="${2:-}";     shift 2 ;;
        --post)    POST="${2:-}";    shift 2 ;;
        --log)     LOG="${2:-}";     shift 2 ;;
        --scope)   SCOPE="${2:-}";   shift 2 ;;
        --claimed) CLAIMED="${2:-}"; shift 2 ;;
        --json)    JSON=true;        shift   ;;
        *) usage; exit 2 ;;
      esac
    done
    [ -n "$DIR" ] && [ -n "$PRE" ] && [ -n "$POST" ] || { usage; exit 2; }
    [ -d "$DIR" ] || die "no such directory: $DIR"
    git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $DIR"
    git -C "$DIR" cat-file -e "$PRE^{tree}"  2>/dev/null || die "--pre is not a tree in $DIR: $PRE"
    git -C "$DIR" cat-file -e "$POST^{tree}" 2>/dev/null || die "--post is not a tree in $DIR: $POST"

    ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$DIR")"

    # Paths from the tree diff are repo-root-relative; paths from a run log or
    # a worker's report are usually absolute. Normalize everything to
    # root-relative so the set operations compare like with like.
    rel_path() {
      local p="$1"
      case "$p" in
        "$ROOT"/*) p="${p#"$ROOT"/}" ;;
        "$DIR"/*)  p="${p#"$DIR"/}"  ;;
      esac
      printf '%s' "${p#./}"
    }

    NOOP=false
    if [ "$(git -C "$DIR" rev-parse "$PRE^{tree}")" = "$(git -C "$DIR" rev-parse "$POST^{tree}")" ]; then
      NOOP=true
    fi

    # --- observed change set (THE core fact: a tree diff, not git status) ---
    # --name-status status letters are read but not kept: every signal below is
    # derived from blob identity, which is strictly more reliable than the
    # letter (a D here says "gone at POST", it does not say whether the file was
    # ever committed).
    OBSERVED=""
    while IFS="$(printf '\t')" read -r st p; do
      [ -n "${p:-}" ] || continue
      : "$st"
      if is_excluded "$p"; then continue; fi
      OBSERVED="$OBSERVED$p
"
    done <<EOF
$(git -C "$DIR" -c core.quotePath=false diff-tree -r --name-status "$PRE" "$POST" || true)
EOF

    # --- churn -------------------------------------------------------------
    ADDED=0 REMOVED=0
    while IFS="$(printf '\t')" read -r a d p; do
      [ -n "${p:-}" ] || continue
      if is_excluded "$p"; then continue; fi
      [ "$a" = "-" ] && continue   # binary file: numstat reports "-  -"
      ADDED=$((ADDED + a))
      REMOVED=$((REMOVED + d))
    done <<EOF
$(git -C "$DIR" -c core.quotePath=false diff --numstat "$PRE" "$POST" || true)
EOF

    # --- reverted (CRITICAL) & deletions (CRITICAL) ------------------------
    # Revert rule: the path's POST blob equals its HEAD blob while its PRE blob
    # differed. That is exactly "the run put this file back to committed state",
    # which is what destroys a peer's uncommitted work. Verified on a
    # reproduction to flag the destroyed peer file and NOT the run's own
    # legitimate edit. A path that existed only at PRE (never committed) and is
    # gone at POST also satisfies this — h and post are both absent — and that
    # is deliberate: deleting a peer's brand-new file is the same destruction.
    # blob_at <treeish> <path> -> blob sha, or "-" when the path is absent there.
    # --verify -q is load-bearing: a plain `git rev-parse <tree>:<missing>` ECHOES
    # THE UNRESOLVED ARGUMENT BACK ON STDOUT before failing, so the obvious
    # `|| echo -` fallback yields a two-line value that never compares equal to
    # "-" and silently disables both critical signals.
    blob_at() {
      local sha
      sha="$(git -C "$DIR" rev-parse --verify -q "$1:$2" 2>/dev/null || true)"
      printf '%s' "${sha:--}"
    }

    REVERTED="" DELETIONS=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      h="$(blob_at HEAD "$p")"
      pre="$(blob_at "$PRE" "$p")"
      post="$(blob_at "$POST" "$p")"
      if [ "$post" = "$h" ] && [ "$pre" != "$h" ]; then
        REVERTED="$REVERTED$p
"
      fi
      # A deletion only counts as destruction when the file was committed;
      # removing a scratch file the run itself created is not interesting.
      if [ "$post" = "-" ] && [ "$h" != "-" ]; then
        DELETIONS="$DELETIONS$p
"
      fi
    done <<EOF
$OBSERVED
EOF

    # --- out of scope (FAIL) ----------------------------------------------
    OUT_OF_SCOPE=""
    if [ -n "$SCOPE" ]; then
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! matches_scope "$p"; then OUT_OF_SCOPE="$OUT_OF_SCOPE$p
"; fi
      done <<EOF
$OBSERVED
EOF
    fi

    # --- report fidelity (FAIL below 0.50) --------------------------------
    FIDELITY="" FIDELITY_HIT=0 FIDELITY_TOTAL=0 CLAIMED_LIST=""
    if [ -n "$CLAIMED" ]; then
      old_ifs="$IFS"; IFS=':'
      for c in $CLAIMED; do
        [ -n "$c" ] || continue
        c="$(rel_path "$c")"
        if is_excluded "$c"; then continue; fi
        CLAIMED_LIST="$CLAIMED_LIST$c
"
      done
      IFS="$old_ifs"
      FIDELITY_TOTAL="$(list_count "$OBSERVED")"
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if list_has "$CLAIMED_LIST" "$p"; then FIDELITY_HIT=$((FIDELITY_HIT + 1)); fi
      done <<EOF
$OBSERVED
EOF
      # An empty observed set means the claim is trivially complete — 1.00, not
      # a division by zero.
      FIDELITY="$(awk -v n="$FIDELITY_HIT" -v d="$FIDELITY_TOTAL" \
        'BEGIN { printf "%.2f", (d == 0 ? 1 : n / d) }')"
    fi

    # --- what the run's tool calls claim to have written (INFO) ------------
    WROTE="" WROTE_NOT_OBSERVED="" OBSERVED_NOT_WROTE=""
    if [ -n "$LOG" ]; then
      [ -f "$LOG" ] || die "no such log file: $LOG"
      # fromjson? | objects mirrors or-worker.sh / or-monitor.sh: the log is
      # NDJSON interleaved with stderr text and bare JSON scalars, all of which
      # must be skipped silently rather than crash the parse.
      raw="$(jq -rR '
        fromjson? | objects
        | select(.type == "assistant")
        | .message.content[]? | objects
        | select(.type == "tool_use")
        | select(.name == "Edit" or .name == "Write"
              or .name == "MultiEdit" or .name == "NotebookEdit")
        | (.input.file_path // .input.notebook_path // empty)
        | strings
      ' "$LOG" 2>/dev/null || true)"
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        p="$(rel_path "$p")"
        if is_excluded "$p"; then continue; fi
        if ! list_has "$WROTE" "$p"; then WROTE="$WROTE$p
"; fi
      done <<EOF
$raw
EOF
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! list_has "$OBSERVED" "$p"; then WROTE_NOT_OBSERVED="$WROTE_NOT_OBSERVED$p
"; fi
      done <<EOF
$WROTE
EOF
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! list_has "$WROTE" "$p"; then OBSERVED_NOT_WROTE="$OBSERVED_NOT_WROTE$p
"; fi
      done <<EOF
$OBSERVED
EOF
    fi

    # --- verdict -----------------------------------------------------------
    EXIT=0 VERDICT="pass"
    FIDELITY_FAIL=false
    if [ -n "$FIDELITY" ] && awk -v f="$FIDELITY" 'BEGIN { exit !(f < 0.50) }'; then
      FIDELITY_FAIL=true
    fi
    if [ -n "$OUT_OF_SCOPE" ] || [ "$FIDELITY_FAIL" = true ]; then
      EXIT=1; VERDICT="fail"
    fi
    # Critical outranks fail.
    if [ -n "$REVERTED" ] || [ -n "$DELETIONS" ]; then
      EXIT=2; VERDICT="critical"
    fi

    # --- render ------------------------------------------------------------
    if $JSON; then
      jq -nc \
        --arg dir "$DIR" --arg pre "$PRE" --arg post "$POST" \
        --arg verdict "$VERDICT" --argjson exit "$EXIT" \
        --argjson noop "$NOOP" \
        --argjson added "$ADDED" --argjson removed "$REMOVED" \
        --argjson observed "$(to_json_array "$OBSERVED")" \
        --argjson reverted "$(to_json_array "$REVERTED")" \
        --argjson deletions "$(to_json_array "$DELETIONS")" \
        --argjson oos "$([ -n "$SCOPE" ] && to_json_array "$OUT_OF_SCOPE" || echo null)" \
        --argjson fidelity "${FIDELITY:-null}" \
        --argjson wrote "$([ -n "$LOG" ] && to_json_array "$WROTE" || echo null)" \
        --argjson wno "$([ -n "$LOG" ] && to_json_array "$WROTE_NOT_OBSERVED" || echo null)" \
        --argjson onw "$([ -n "$LOG" ] && to_json_array "$OBSERVED_NOT_WROTE" || echo null)" \
        '{dir:$dir, pre:$pre, post:$post, noop:$noop, observed:$observed,
          churn:{added:$added, deleted:$removed},
          reverted_paths:$reverted, deletions:$deletions, out_of_scope:$oos,
          report_fidelity:$fidelity, wrote_paths:$wrote,
          wrote_not_observed:$wno, observed_not_wrote:$onw,
          verdict:$verdict, exit:$exit}'
    else
      echo "EVIDENCE CARD  $DIR"
      echo "  pre  ${PRE}"
      echo "  post ${POST}"
      echo "  changed: $(list_count "$OBSERVED") file(s)   churn: +${ADDED} / -${REMOVED}"
      if [ "$NOOP" = true ]; then
        echo "  WARN      noop — PRE and POST are identical; the run changed nothing"
      fi
      if [ -n "$OBSERVED" ]; then
        echo "  observed:"
        printf '%s' "$OBSERVED" | sed 's/^/    /'
      fi
      if [ -n "$REVERTED" ]; then
        echo "  CRITICAL  reverted_paths — POST blob == HEAD while PRE differed (work destroyed):"
        printf '%s' "$REVERTED" | sed 's/^/    /'
      fi
      if [ -n "$DELETIONS" ]; then
        echo "  CRITICAL  deletions — committed file present at PRE, gone at POST:"
        printf '%s' "$DELETIONS" | sed 's/^/    /'
      fi
      if [ -n "$OUT_OF_SCOPE" ]; then
        echo "  FAIL      out_of_scope — changed but matching no --scope glob ('$SCOPE'):"
        printf '%s' "$OUT_OF_SCOPE" | sed 's/^/    /'
      fi
      if [ -n "$FIDELITY" ]; then
        if [ "$FIDELITY_FAIL" = true ]; then lbl="FAIL     "; else lbl="ok       "; fi
        echo "  $lbl report_fidelity $FIDELITY  ($FIDELITY_HIT of $FIDELITY_TOTAL observed path(s) were claimed)"
      fi
      if [ -n "$LOG" ]; then
        echo "  INFO      wrote_paths: $(list_count "$WROTE") from tool calls"
        if [ -n "$WROTE_NOT_OBSERVED" ]; then
          echo "  INFO      wrote_not_observed — written per the log, absent from the tree diff:"
          printf '%s' "$WROTE_NOT_OBSERVED" | sed 's/^/    /'
        fi
        if [ -n "$OBSERVED_NOT_WROTE" ]; then
          echo "  INFO      observed_not_wrote — changed in the tree with no matching tool call:"
          printf '%s' "$OBSERVED_NOT_WROTE" | sed 's/^/    /'
        fi
      fi
      echo "  VERDICT: $(echo "$VERDICT" | tr 'a-z' 'A-Z') (exit $EXIT)"
    fi
    exit "$EXIT"
    ;;

  *)
    usage
    exit 2
    ;;
esac
