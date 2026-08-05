---
name: openrouter
description: Call non-Anthropic models (DeepSeek, Qwen, GLM, Kimi, etc.) from Claude Code via OpenRouter. Two dispatch modes - a curl-based one-shot "oracle" (or-chat.sh) for generation/review from supplied context, and fully agentic headless workers (or-proxy.sh + or-worker.sh) that run claude -p on an OpenRouter model through a local LiteLLM gateway. Use when the user asks to use DeepSeek/OpenRouter/another provider's model, wants a cheap second opinion, or /orchestrate-deepseek needs its plumbing.
argument-hint: <model or task>
---

# OpenRouter dispatch

All scripts live in this skill's `scripts/` directory. Resolve it as:
`OR="$HOME/.claude/skills/openrouter/scripts"`.

## API key (never inline it)

Key resolution order, handled identically on every platform by the shared `scripts/or-common.sh` (sourced by the scripts that need a key — `or-chat.sh`, `or-proxy.sh`, `setup.sh`): `$OPENROUTER_API_KEY` env var, then OS keyring (macOS Keychain item `openrouter-api-key` via `security`; Linux Secret Service via `secret-tool` if on PATH, non-fatal if missing; Windows skipped), then a plain 0600 key file at `${XDG_CONFIG_HOME:-$HOME/.config}/openrouter/key` on macOS/Linux or `${APPDATA:-$HOME/AppData/Roaming}/openrouter/key` on Windows. Never paste a key into a prompt, file, or command line. If no key resolves, the scripts exit 3 with per-OS setup instructions; relay those to the user. `setup.sh <key>` stores it via the best backend for the platform. On Windows the key file is not encrypted at rest (no DPAPI/Credential Manager integration); WSL is the recommended Windows route for full parity.

Sanity check: `$OR/or-chat.sh key-check` (prints label + usage on success).

## Choosing a model — query live, don't trust memory

Model IDs and pricing churn. List them live (no key required):

```bash
$OR/or-chat.sh models deepseek        # filter by substring, TSV: id, context, $/prompt-tok, $/completion-tok
```

Defaults chosen 2026-08-05 (re-verify with `models` if it matters):
- `~deepseek/deepseek-v4-flash-latest` — DEFAULT for both workers and oracles ($0.09/$0.18 per MTok, 1M ctx). The leading `~` is literal (OpenRouter's rolling alias, resolves to the newest flash snapshot — currently 0731) — ALWAYS single-quote the id in shell or the tilde may expand. Override worker default via `OR_WORKER_MODEL` env or `-m`. Note plain `deepseek/deepseek-v4-flash` is pinned to the OLDER 0423 snapshot at higher price — don't use it.
- `deepseek/deepseek-v4-pro` — first escalation for packets flash fumbles ($0.435/$0.87, 1M ctx)
- `deepseek/deepseek-r1-0528` — reasoning-heavy one-shots

## Mode 1 — oracle (one-shot, no tools): `or-chat.sh chat`

For generation, review, or second opinions where YOU supply all context and apply the output. The model cannot read files, run commands, or iterate.

```bash
$OR/or-chat.sh chat -m '~deepseek/deepseek-v4-flash-latest' -s system.md prompt.md   # or "-" / omit for stdin
```

Flags: `-m` model (required), `-s` system-prompt file, `-t` temperature, `-x` max_tokens (default 32768 — reasoning budget is carved out of this, max effort ≈ 95%, so don't shrink it carelessly), `-e` reasoning effort max|xhigh|high|medium|low|minimal (default max; pass `none` to omit the param for cheap bulk generation or non-reasoning models). Content → stdout; token usage → stderr; API errors → stderr + exit 1.

Rules for good oracle packets:
- Write the prompt to a scratchpad file; don't shell-escape large prompts inline.
- Paste every file/snippet the task needs — the model sees nothing else.
- Pin the output format ("reply with ONLY a unified diff against the pasted files" / "ONLY the full replacement file, no fences") so applying it is mechanical.
- You (the session) apply the output with Edit/Write and verify it — never assume oracle output compiles.

## Mode 2 — agentic worker (real tools): `or-proxy.sh` + `or-worker.sh`

For self-contained implementation packets where the model must read files, edit, and iterate — a true worker, like the Agent tool but billed at OpenRouter rates.

```bash
$OR/or-proxy.sh start      # once per machine session; idempotent. stop/status/logs also available.
$OR/or-worker.sh -d /path/to/repo packet.md
```

**Parallel workers on one repo MUST use `-w` (worktree isolation).** Workers sharing a checkout race: they see each other's half-finished edits, mistake them for their own overreach, and `git checkout` them away. This has destroyed completed work. `-w` gives each worker a detached worktree from HEAD (so commit or stash anything it must build on first); an unchanged worktree is auto-removed, a dirty one is kept for you to review and merge. Sequence workers instead only when they genuinely must build on each other.

Worker flags: `-m` model (default `~deepseek/deepseek-v4-flash-latest`), `-d` workdir, `-w` worktree isolation, `-n` max turns (default 50), `-e` effort low|medium|high|xhigh|max (default max, or `$OR_WORKER_EFFORT`; best-effort through the gateway — drop_params discards it where the model can't honor it), `-r <session-id>` to continue a previous worker (follow-up fixes — reuse, don't respawn), `-y` bypassPermissions (default is acceptEdits: edits allowed, Bash blocked — keep the default and let a verifier run commands, unless the packet genuinely needs to execute things).

Output is JSON: `.result` (worker's report), `.session_id` (for `-r`), `.total_cost_usd`, `.usage`. Extract with jq.

Worker packets follow the same contract as /orchestrate packets: objective, exact files, pasted context it can't discover, acceptance criteria, required report shape. The worker shares none of your conversation context.

Run long workers via Bash `run_in_background: true` and dispatch independent packets in parallel.

## Worker guardrails (enforced, not advisory)

Every worker runs under `worker-settings.json` (override via `$OR_WORKER_SETTINGS`) plus a rules preamble prepended to its packet. Verified by red-team probes 2026-08-05: the harness hard-denies these even under `-y`, returning "Permission to use Bash with command … has been denied" / "File is in a directory that is denied by your permission settings".

- **Secrets are unreadable:** `.env*`, `*.key`, `*.pem`, SSH/AWS creds, `.npmrc`, `.netrc` — Read and Edit both denied (dotfile, wildcard-extension, and nested-path globs all confirmed matching).
- **No database or cloud CLIs:** psql, mysql, mongosh, redis-cli, sqlite3, pg_dump, heroku, aws, az, gcloud, gh.
- **No destructive git:** checkout, restore, reset, clean, stash, commit, push. This is what wiped 18 files in the incident that prompted these rules.
- **No network/env exfil:** curl, wget, env, printenv, WebFetch, WebSearch.
- The `OPENROUTER_API_KEY` is stripped from the worker's environment (it never needs it).

The preamble tells the worker to treat a denial as a **blocker to report**, not an obstacle to route around, and to ask the orchestrator for any config value it can't read. When a packet needs a secret, YOU read it and paste a sanitized value into the packet — never widen the deny list to let the worker fetch it.

## Native-agent dispatch (monitorable in the UI)

Prefer launching DeepSeek workers through the `deepseek-worker` agent (Agent tool, `subagent_type: "deepseek-worker"`) instead of calling `or-worker.sh` yourself: it's a Haiku-cheap chaperone that starts the gateway, dispatches the packet to the script, sanity-checks the resulting diff, and relays the report — and because it's a native agent, the run is visible/monitorable in the harness UI and continuable via SendMessage (follow-ups resume the same DeepSeek session via `-r`). Give it the full WORK PACKET in its prompt; add a `RESUME SESSION: <id>` line for follow-up fixes. Call the script directly only for large scripted fan-outs (loops, Workflow) where per-run chaperones add no value.

## Monitoring runs

- Every worker streams NDJSON progress to `runs/<timestamp>-<label>.jsonl` in this skill's directory (path announced on stderr at dispatch).
- `$OR/or-monitor.sh list` — all runs with status/cost/turns; `watch [log]` — live-tail a run (defaults to newest; for the user's own terminal); `show [log]` — render a finished transcript.
- Workers are real Claude Code sessions: their transcripts also appear under `claude --resume` in the workdir. View-only — typing there would send a `deepseek/*` model id to Anthropic auth and fail; continue workers with `or-worker.sh -r <session-id>` (or a follow-up to the chaperone agent) instead.

## Claude Desktop bridge

`mcp/server.py` exposes this skill to the Claude Desktop chat app as MCP tools (`deepseek_chat`, `deepseek_worker_start`/`_check` with a start→poll contract, `deepseek_runs_list`, `openrouter_gateway`), registered as `deepseek-openrouter` in the per-OS Desktop config (`~/Library/Application Support/Claude/` on macOS, `%APPDATA%/Claude/` on Windows, `${XDG_CONFIG_HOME:-~/.config}/Claude/` on Linux) (runs via `uv run --with mcp`). Workers dispatched from Desktop land in the same `runs/` directory, so `or-monitor.sh` and this session see them too.

## Caveats

- Non-Anthropic models through the Anthropic-API translation layer have flakier tool-calling than native Claude — expect occasional mangled edits; always verify diffs (verifier agent or yourself).
- First `or-proxy.sh start` downloads litellm via uvx (1–3 min); later starts are fast.
- The gateway binds 127.0.0.1 only; port via `OR_PROXY_PORT` (default 4141).
- Costs bill to the user's OpenRouter account, outside Claude usage — mention spend when it's non-trivial (`.total_cost_usd` from workers, usage line from the oracle).
- Never send secrets, credentials, or private user data in packet content — it goes to a third-party provider.
