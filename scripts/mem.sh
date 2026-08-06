#!/usr/bin/env bash
# mem.sh — fast retrieval over the file-based memory store.
#
# Why ripgrep and not an index: the memory corpus is dominated by code
# identifiers, and SQLite FTS5's tokenizer cannot match `risk` inside
# `redactRiskCellsForExport` (measured: 0 hits) while `rg -i risk` finds every
# one in ~0 ms. A vector or FTS index here would be slower to build, staler, and
# strictly worse at the dominant query shape. Measured at 145 files across 6
# projects; brute-force search stays sub-10ms well past 10x that.
#
# Usage:
#   mem.sh search <query> [--project <dir-name>]   # ranked matches with context
#   mem.sh show <name>                             # print one memory in full
#   mem.sh list [--project <dir-name>]             # names + one-line descriptions
#   mem.sh unresolved [repo]                       # memories citing paths absent from the current checkout
#   mem.sh size                                    # token cost of what loads every session
set -euo pipefail

ROOT="${CLAUDE_MEMORY_ROOT:-$HOME/.claude/projects}"
PROJECT=""

# rg is the whole point; degrade loudly rather than silently using grep.
command -v rg >/dev/null 2>&1 || { echo "ERROR: ripgrep (rg) is required." >&2; exit 3; }

memdirs() {
  if [ -n "$PROJECT" ]; then
    printf '%s\n' "$ROOT/$PROJECT/memory"
  else
    find "$ROOT" -maxdepth 2 -type d -name memory 2>/dev/null
  fi
}

# The `description:` frontmatter line is the memory's own summary — better as a
# result label than the filename or a raw match line.
describe() { rg -m1 -N --no-filename '^description:' "$1" 2>/dev/null | sed 's/^description: *//' | cut -c1-110; }

cmd="${1:-}"; shift || true
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

case "$cmd" in
  search)
    [ "${#args[@]}" -gt 0 ] || { echo "usage: mem.sh search <query>" >&2; exit 2; }
    q="${args[*]}"
    found=0
    while IFS= read -r d; do
      [ -d "$d" ] || continue
      # -l first so each memory is reported once, however many times it matches.
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        found=1
        printf '\n\033[1m%s\033[0m  (%s)\n' "$(basename "$f" .md)" "$(basename "$(dirname "$(dirname "$f")")")"
        d_desc="$(describe "$f")"; [ -n "$d_desc" ] && printf '  %s\n' "$d_desc"
        rg -i -N --no-filename --max-count 3 -C0 "$q" "$f" 2>/dev/null \
          | grep -v '^description:' | head -3 | sed 's/^/    | /' | cut -c1-160
      done < <(rg -il "$q" "$d" --glob '*.md' --glob '!MEMORY.md' 2>/dev/null || true)
    done < <(memdirs)
    [ "$found" = 1 ] || { echo "no memory matches: $q"; exit 1; }
    ;;

  show)
    [ "${#args[@]}" -gt 0 ] || { echo "usage: mem.sh show <name>" >&2; exit 2; }
    n="${args[0]%.md}"
    while IFS= read -r d; do
      [ -f "$d/$n.md" ] && { cat "$d/$n.md"; exit 0; }
    done < <(memdirs)
    # Fall back to a fuzzy hit so a half-remembered name still resolves.
    while IFS= read -r d; do
      f="$(find "$d" -name "*${n}*.md" 2>/dev/null | head -1)"
      [ -n "$f" ] && { cat "$f"; exit 0; }
    done < <(memdirs)
    echo "no such memory: $n" >&2; exit 1
    ;;

  list)
    while IFS= read -r d; do
      [ -d "$d" ] || continue
      for f in "$d"/*.md; do
        [ -e "$f" ] || continue
        case "$(basename "$f")" in MEMORY.md) continue ;; esac
        printf '  %-52s %s\n' "$(basename "$f" .md)" "$(describe "$f")"
      done
    done < <(memdirs)
    ;;

  unresolved|stale)
    # Memories go stale silently: they name a file that has since been renamed or
    # deleted, and a later session acts on a path that no longer exists.
    #
    # Scoped to ONE repo deliberately. Memory paths are written relative to their
    # project root, so resolving them against the cwd (or across all projects at
    # once) reports every path in every other project as missing — 652 lines of
    # noise on this machine, which is worse than no check at all.
    REPO="${args[0]:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
    [ -n "$REPO" ] && [ -d "$REPO" ] || {
      echo "usage: mem.sh stale [repo-root]   (run inside a git repo, or pass its root)" >&2; exit 2; }
    MEMDIR="$ROOT/$(printf '%s' "$REPO" | sed 's|/|-|g')/memory"
    [ -d "$MEMDIR" ] || { echo "no memory directory for $REPO" >&2; exit 1; }
    echo "memories citing paths not present in the current checkout of $REPO"
    echo "(absent != stale: branch-scoped work is expected to be missing on main)"
    # One index of every tracked basename; a memory that cites `run.ts` without a
    # directory is current if any run.ts still exists somewhere in the repo.
    idx="$(mktemp)"; git -C "$REPO" ls-files 2>/dev/null > "$idx" || true
    names="$(mktemp)"; sed 's|.*/||' "$idx" | sort -u > "$names"
    hits=0
    for f in "$MEMDIR"/*.md; do
      [ -e "$f" ] || continue
      case "$(basename "$f")" in MEMORY.md) continue ;; esac   # the index cites everything
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in http*|*.md|*node_modules*) continue ;; esac
        [ -e "$REPO/$p" ] && continue                       # exact path still there
        grep -qxF "$p" "$idx" && continue                   # tracked at that path
        grep -qxF "${p##*/}" "$names" && continue           # basename exists somewhere
        hits=$((hits + 1))
        printf '  %-46s %s\n' "$(basename "$f" .md)" "$p"
        # Two precision rules learned by running this against the real corpus:
        #   - alternation is leftmost-FIRST, so `tsx` must precede `ts` or every
        #     `_app.tsx` is reported as a missing `_app.ts`;
        #   - require a `/` in the token, so prose product names (Next.js,
        #     Three.js, pdf.js) are not mistaken for paths. Bare basenames are
        #     nearly always prose; citing a path means writing a path.
      done < <(rg -o -N --no-filename '[a-zA-Z0-9_.-]+/[a-zA-Z0-9_./-]+\.(tsx|ts|jsx|js|py|sql|sh|yaml|yml)' "$f" 2>/dev/null | sort -u)
    done
    rm -f "$idx" "$names"
    [ "$hits" = 0 ] && echo "  (none — every cited path resolves here)"
    echo "  $hits unresolved reference(s) — check each against its branch before editing the memory"
    ;;

  size)
    # MEMORY.md is loaded into context every session, so its size is a recurring
    # per-session tax; the individual notes are only read on demand.
    while IFS= read -r d; do
      [ -f "$d/MEMORY.md" ] || continue
      b=$(wc -c < "$d/MEMORY.md"); n=$(ls "$d"/*.md 2>/dev/null | wc -l | tr -d ' ')
      printf '  %-34s index %6s bytes (~%5s tokens/session)  %3s notes\n' \
        "$(basename "$(dirname "$d")")" "$b" "$((b / 4))" "$n"
    done < <(memdirs)
    ;;

  *)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
