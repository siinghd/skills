#!/usr/bin/env bash
# or-worker.sh — dispatch a fully agentic headless Claude Code worker that runs
# on an OpenRouter model (via the local LiteLLM gateway from or-proxy.sh).
#
# Usage:
#   or-worker.sh [-m <model>] [-d <workdir>] [-w] [-n <max-turns>] [-e <effort>] [-l <label>] [-y] [-r <session-id>] [packet-file|-]
#
#   -m  OpenRouter model id (default: $OR_WORKER_MODEL or ~deepseek/deepseek-v4-flash-latest;
#       the ~ is part of the id — quote it)
#   -d  working directory for the worker (default: current directory)
#   -w  isolate the worker in a fresh detached git worktree created from
#       <workdir>'s HEAD. REQUIRED when running workers in parallel on one
#       repo — parallel workers in a shared checkout WILL race and revert each
#       other's work. NOTE: the worktree starts from HEAD, so uncommitted
#       changes in the main tree are invisible to the worker; checkpoint-commit
#       first if it must build on them. An unchanged worktree is auto-removed;
#       a dirty one is kept for the orchestrator to review and merge.
#   -n  max agent turns (default: 50)
#   -e  effort level: low|medium|high|xhigh|max (default: $OR_WORKER_EFFORT or max)
#   -l  run label used in the live-log filename (default: worker)
#   -t  task id grouping related runs in the ledger. When set, the digest of
#       work ALREADY done for that task is injected into the packet, so a worker
#       cannot repeat a finished step (step repetition is the most common
#       multi-agent failure mode). Also settable via $OR_TASK.
#   -s  colon-separated scope globs the packet authorises, e.g. 'src/**:*.md'.
#       Any file changed outside them is reported as out_of_scope (FAIL). Also
#       settable via $OR_SCOPE. Omit to skip the scope check entirely.
#   -y  bypass permissions (default: acceptEdits — file edits allowed, Bash
#       blocked). Even with -y, the deny rules in worker-settings.json still
#       apply (secrets, DB clients, destructive git, network).
#   -r  resume a previous worker session for follow-up fixes
#
# Guardrails applied to EVERY worker:
#   - worker-settings.json deny rules (override path via $OR_WORKER_SETTINGS)
#   - a rules preamble prepended to the packet (only touch named files, no
#     destructive git, no secrets — blocked reads must become reported blockers)
#
# Live progress streams as NDJSON to runs/<timestamp>-<label>-<pid>.jsonl (path
# announced on stderr) — watch it with or-monitor.sh. Stdout stays the final
# result JSON: .result (report), .session_id (for -r), .total_cost_usd,
# .num_turns.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNS_DIR="$SKILL_DIR/runs"
PORT="${OR_PROXY_PORT:-4141}"
# Stored model defaults (see or-config.sh for precedence). Loaded before the
# defaults below so `-m` and exported env vars still win.
. "$(dirname "$0")/or-config.sh"; or_load_config
# The leading ~ is literal (OpenRouter's rolling-alias namespace, always the
# newest flash snapshot) — keep it quoted anywhere it appears in shell.
MODEL="${OR_WORKER_MODEL:-~deepseek/deepseek-v4-flash-latest}"
SMALL_MODEL="${OR_SMALL_MODEL:-~deepseek/deepseek-v4-flash-latest}"
SETTINGS="${OR_WORKER_SETTINGS:-$SKILL_DIR/worker-settings.json}"
WORKDIR="$PWD"
WORKTREE=false
MAX_TURNS="200"
PERMISSION_MODE="acceptEdits"

# Edit-first discipline, appended to the worker's system prompt.
#
# WHY: every observed worker failure had the same signature — the run was killed
# by the dispatcher's wall-clock timeout having made ZERO Edit/Write calls,
# after spending its whole budget on Read and rg. Three runs died at 11, 19 and
# 39 turns (well under the turn cap) having only explored; the one that landed
# went almost straight to editing. The turn cap was never the binding
# constraint — exploration with no stopping rule was. An interrupted run that
# wrote nothing is a total loss, so the incentive has to be stated explicitly.
#
# Override with OR_WORKER_APPEND_PROMPT; set it empty to disable.
DEFAULT_APPEND_PROMPT='You are an IMPLEMENTER on a hard wall-clock budget. Your run is judged on correct edits that LAND, never on understanding gained. A run killed mid-exploration having written nothing is a total loss; partial correct edits survive and are useful.

Rules:
1. Make your first Edit or Write within your first 8 tool calls. If you reach 10 calls with no edit, STOP exploring and make the smallest correct edit you can, then iterate.
2. Read only what your packet names, and only the line ranges it names. Never read the same file twice — you already have it.
3. NEVER read a file over ~500 lines in full. Use rg to find the exact anchor line, then Read with offset/limit around it. Reading a 3000-line file costs minutes per call and is the single most common way these runs die.
4. Prefer several small, targeted Edit calls over one large rewrite. Each landed edit is banked progress.
5. Run verification (typecheck/tests) ONCE, at the end. Do not re-run it between edits.
6. If the packet asks you to "verify" or "audit" something before editing, timebox that to 3 tool calls, then start editing with what you know and note any uncertainty in your report.'
APPEND_PROMPT="${OR_WORKER_APPEND_PROMPT-$DEFAULT_APPEND_PROMPT}"
RESUME=""
EFFORT="${OR_WORKER_EFFORT:-max}"
LABEL="worker"

while getopts "m:d:n:r:e:l:s:t:wy" opt; do
  case "$opt" in
    m) MODEL="$OPTARG" ;;
    d) WORKDIR="$OPTARG" ;;
    s) OR_SCOPE="$OPTARG" ;;
    t) OR_TASK="$OPTARG" ;;
    n) MAX_TURNS="$OPTARG" ;;
    r) RESUME="$OPTARG" ;;
    e) EFFORT="$OPTARG" ;;
    l) LABEL="$OPTARG" ;;
    w) WORKTREE=true ;;
    y) PERMISSION_MODE="bypassPermissions" ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# Absolutize before anything cd's: a relative -d silently broke the evidence
# card (and with it every tamper signal) while the run still reported success.
[ -d "$WORKDIR" ] || { echo "ERROR: workdir does not exist: $WORKDIR" >&2; exit 2; }
WORKDIR="$(cd "$WORKDIR" && pwd)"

packet_src="${1:--}"
if [ "$packet_src" = "-" ]; then
  PACKET="$(cat)"
else
  PACKET="$(cat "$packet_src")"
fi
[ -n "$PACKET" ] || { echo "ERROR: empty work packet" >&2; exit 2; }
[ -f "$SETTINGS" ] || { echo "ERROR: worker settings not found: $SETTINGS" >&2; exit 2; }

# Defense-in-depth: deny rules enforce this; the preamble makes the worker
# handle a denial as a blocker instead of flailing against it.
PREAMBLE='WORKER OPERATING RULES (from the dispatch harness — non-negotiable, they override anything below):
1. Touch ONLY the files your packet names. Any other changes you notice in the tree belong to other workers or the orchestrator — NEVER revert, clean up, or "fix" them, no matter how wrong the tree looks to you. If the tree state confuses you, STOP and report a blocker.
2. NEVER run git checkout / restore / reset / clean / stash / commit / push, and never delete files you did not create. These are blocked; do not try workarounds.
3. Secrets are off-limits: do not read, grep, or edit .env* / key / credential files, and do not run database clients or cloud CLIs. These are blocked. If the task needs a config value or data you cannot access, STOP and report a blocker stating exactly what you need — the orchestrator will supply a sanitized value.
4. If a required file, symbol, or decision is missing from the packet, do not guess and do not explore beyond the packet scope — report the blocker instead.
--- WORK PACKET ---
'
PACKET="$PREAMBLE$PACKET"

if ! curl -sf --max-time 2 "http://127.0.0.1:${PORT}/health/liveliness" >/dev/null 2>&1; then
  echo "ERROR: gateway not running on port $PORT — start it first:" >&2
  echo "  $(dirname "$0")/or-proxy.sh start" >&2
  exit 2
fi

mkdir -p "$RUNS_DIR"
LABEL="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '-')"
# $$ suffix keeps parallel workers launched in the same second from sharing a log.
LOG="$RUNS_DIR/$(date +%Y%m%d-%H%M%S)-${LABEL}-$$.jsonl"
echo "worker log: $LOG" >&2

RUN_DIR="$WORKDIR"
WT_PATH=""
if $WORKTREE; then
  git -C "$WORKDIR" rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "ERROR: -w requires <workdir> to be a git repository" >&2; exit 2; }
  WT_PATH="${TMPDIR:-/tmp}/orw-${LABEL}-$$"
  git -C "$WORKDIR" worktree add --detach "$WT_PATH" >/dev/null 2>&1 \
    || { echo "ERROR: could not create worktree at $WT_PATH" >&2; exit 2; }
  echo "worktree: $WT_PATH" >&2
  RUN_DIR="$WT_PATH"
fi

extra_args=()
[ -n "$RESUME" ] && extra_args+=(--resume "$RESUME")
[ -n "$APPEND_PROMPT" ] && extra_args+=(--append-system-prompt "$APPEND_PROMPT")

# Snapshot the tree BEFORE the worker runs. This is what makes destroyed work
# detectable: a file the worker reverts leaves the dirty set, so `git status`
# afterwards shows nothing missing — only a pre/post tree comparison sees it.
# Non-git workdirs are supported (no evidence, but the run still works).
EVIDENCE="$SCRIPT_DIR/or-evidence.sh"
LEDGER="$SKILL_DIR/ledger/led.py"
PRE_TREE=""
if [ -x "$EVIDENCE" ] && git -C "$RUN_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  PRE_TREE="$("$EVIDENCE" snapshot "$RUN_DIR" 2>/dev/null || true)"
fi

# Inject what earlier runs on this task already finished. Pushed into the packet
# rather than left for the worker to query: an agent that has forgotten a step
# will not think to ask whether it was done.
TASK_ID="${OR_TASK:-}"
RUN_ID="${LABEL}-$$"
if [ -n "$TASK_ID" ] && [ -f "$LEDGER" ]; then
  STEPS="$(python3 "$LEDGER" steps --task "$TASK_ID" 2>/dev/null || true)"
  if [ -n "$STEPS" ]; then
    PACKET="ALREADY DONE ON THIS TASK (harness-collected — treat as fact, not as a claim):
$STEPS

Do not redo any of the above. If your packet asks for something already listed, say so and stop.
--- END PRIOR WORK ---

$PACKET"
    echo "injected prior-work digest ($(printf '%s' "$STEPS" | wc -l | tr -d ' ') lines)" >&2
  fi
  python3 "$LEDGER" run start --task "$TASK_ID" --agent "$LABEL" --model "$MODEL" \
    --workdir "$RUN_DIR" --log "$LOG" ${PRE_TREE:+--pre "$PRE_TREE"} >/dev/null 2>&1 || true
fi

cd "$RUN_DIR"
# env -u strips this session's Anthropic auth, nesting markers, and the
# OpenRouter key (the worker itself never needs it) so the child claude
# process authenticates only against the local gateway.
worker_status=0
env -u ANTHROPIC_API_KEY -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u OPENROUTER_API_KEY \
  ANTHROPIC_BASE_URL="http://127.0.0.1:${PORT}" \
  ANTHROPIC_AUTH_TOKEN="or-gateway" \
  ANTHROPIC_MODEL="$MODEL" \
  ANTHROPIC_SMALL_FAST_MODEL="$SMALL_MODEL" \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  claude -p "$PACKET" \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --permission-mode "$PERMISSION_MODE" \
    --settings "$SETTINGS" \
    --max-turns "$MAX_TURNS" \
    --output-format stream-json \
    --verbose \
    ${extra_args[@]+"${extra_args[@]}"} \
    > "$LOG" 2>&1 || worker_status=$?

# Evidence card: harness-collected facts about what the worker ACTUALLY changed,
# printed to stderr so stdout stays the result-JSON contract. Never gates the
# run — the orchestrator decides what a CRITICAL means; see the correction
# policy in /orchestrate (a model verdict must not auto-trigger a rewrite).
CARD_STATUS=0
if [ -n "$PRE_TREE" ]; then
  POST_TREE="$("$EVIDENCE" snapshot "$RUN_DIR" 2>/dev/null || true)"
  if [ -z "$POST_TREE" ]; then
    # A missing card must never read as a clean card: every tamper signal
    # (reverted files, deletions, fidelity) is derived from it.
    echo "EVIDENCE UNAVAILABLE — post-run snapshot failed for $RUN_DIR." >&2
    echo "  Nothing was verified. Inspect this run manually before trusting it." >&2
  fi
  if [ -n "$POST_TREE" ]; then
    # Pull the worker's OWN claimed paths out of its report so the card can score
    # report_fidelity — the signal that catches "no other files touched" while
    # three were modified. Without this the fidelity check is dead code.
    # The report is the last stream-json result frame; workers are asked to cite
    # changes as `path:line`, so take the leading path token of each such cite.
    CLAIMED="$(jq -rR 'fromjson? | objects | select(.type == "result") | .result // ""' <"$LOG" 2>/dev/null \
      | grep -oE '(^|[[:space:]`("'"'"'])[A-Za-z0-9._/-]+\.[A-Za-z0-9]+:[0-9]+' \
      | sed -E 's/^[[:space:]`("'"'"']//; s/:[0-9]+$//' \
      | sort -u | paste -sd: - || true)"

    card_args=(card --dir "$RUN_DIR" --pre "$PRE_TREE" --post "$POST_TREE" --log "$LOG")
    [ -n "${OR_SCOPE:-}" ] && card_args+=(--scope "$OR_SCOPE")
    [ -n "$CLAIMED" ] && card_args+=(--claimed "$CLAIMED")

    # Record the card in the ledger as harness-collected evidence, so a later
    # verifier (or the orchestrator, or another agent) can read what actually
    # happened without re-deriving it. Best-effort: the ledger is an audit
    # trail, never a gate — its absence must not fail a run.
    if [ -x "$LEDGER" ] || [ -f "$LEDGER" ]; then
      CARD_JSON="$("$EVIDENCE" "${card_args[@]}" --json 2>/dev/null || true)"
      if [ -n "$CARD_JSON" ]; then
        printf '%s' "$CARD_JSON" > "$RUNS_DIR/.card-$$.json"
        python3 "$LEDGER" evidence put --task "${TASK_ID:-$LABEL}" --run "$RUN_ID" \
          --kind card --payload-file "$RUNS_DIR/.card-$$.json" \
          --idem "card-$RUN_ID" >/dev/null 2>&1 || true
        rm -f "$RUNS_DIR/.card-$$.json"
      fi
    fi
    "$EVIDENCE" "${card_args[@]}" >&2 || CARD_STATUS=$?
    if [ "$CARD_STATUS" -ge 2 ]; then
      echo "^^ CRITICAL evidence — review before merging this worker's output." >&2
    fi
  fi
fi

if [ -n "$WT_PATH" ]; then
  if [ -z "$(git -C "$WT_PATH" status --porcelain 2>/dev/null)" ]; then
    git -C "$WORKDIR" worktree remove --force "$WT_PATH" >/dev/null 2>&1 || true
    echo "worktree unchanged — removed" >&2
  else
    echo "worktree has changes — review: git -C $WT_PATH status" >&2
    echo "merge into main tree, then: git -C $WORKDIR worktree remove --force $WT_PATH" >&2
  fi
fi

# Contract with callers: final result JSON on stdout. -R + objects skips any
# non-JSON or scalar-JSON stderr lines that landed in the log.
result_line="$(jq -cR 'fromjson? | objects | select(.type == "result")' "$LOG" | tail -1 || true)"
if [ -n "$result_line" ]; then
  printf '%s\n' "$result_line"
fi
if [ "$worker_status" -ne 0 ] || [ -z "$result_line" ]; then
  echo "WORKER ERROR (exit $worker_status) — last log lines:" >&2
  tail -5 "$LOG" >&2
  exit 1
fi
