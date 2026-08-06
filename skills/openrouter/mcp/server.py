#!/usr/bin/env python3
"""MCP stdio server exposing the openrouter skill to Claude Desktop.

Registered in claude_desktop_config.json; wraps the skill's shell scripts so
Desktop-Claude can run cheap oracles and agentic workers locally on any
OpenRouter-hosted model (DeepSeek is only the default).
Long-running workers use a start/check contract (Desktop tool calls must not
block for minutes).
"""

import glob
import json
import os
import subprocess
import tempfile

from mcp.server.fastmcp import FastMCP

# Derive paths from this file's location so the server works from any checkout
# (~/.claude copy, repo clone, etc.), not just the default install path.
SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(SKILL, "scripts")
RUNS = os.path.join(SKILL, "runs")

mcp = FastMCP("openrouter")


def _run(args, input_text=None, timeout=600):
    return subprocess.run(
        args, input=input_text, capture_output=True, text=True, timeout=timeout
    )


@mcp.tool()
def openrouter_gateway(action: str = "status") -> str:
    """Manage the local LiteLLM gateway (action: start | stop | status).

    The gateway must be running before openrouter_worker_start. 'start' is
    idempotent; first-ever start may take a couple of minutes (downloads).
    """
    if action not in ("start", "stop", "status"):
        return "ERROR: action must be start, stop, or status"
    p = _run([os.path.join(SCRIPTS, "or-proxy.sh"), action], timeout=300)
    return (p.stdout + p.stderr).strip() or f"(exit {p.returncode})"


@mcp.tool()
def openrouter_chat(
    prompt: str,
    model: str = "~deepseek/deepseek-v4-flash-latest",
    system: str = "",
    effort: str = "max",
    max_tokens: int = 32768,
) -> str:
    """One-shot completion on any OpenRouter model (text in, text out — no tools).

    Good for generation, review, or second opinions where the prompt carries
    all needed context. effort: max|xhigh|high|medium|low|minimal|none —
    max can take minutes; use none/low for quick or bulk calls. Does not need
    the gateway.
    """
    args = [
        os.path.join(SCRIPTS, "or-chat.sh"), "chat",
        "-m", model, "-e", effort, "-x", str(max_tokens),
    ]
    sys_path = None
    try:
        if system:
            fd, sys_path = tempfile.mkstemp(suffix=".md", prefix="or-system-")
            with os.fdopen(fd, "w") as f:
                f.write(system)
            args += ["-s", sys_path]
        p = _run(args, input_text=prompt, timeout=900)
    finally:
        if sys_path:
            os.unlink(sys_path)
    if p.returncode != 0:
        return f"ERROR: {p.stderr.strip()}"
    usage = p.stderr.strip().splitlines()
    return p.stdout.rstrip() + (f"\n\n[{usage[-1]}]" if usage else "")


@mcp.tool()
def openrouter_worker_start(
    packet: str,
    workdir: str,
    label: str = "desktop",
    model: str = "",
    resume_session: str = "",
    run_commands: bool = False,
    isolate: bool = False,
) -> str:
    """Start an agentic worker on any OpenRouter model (headless Claude Code with real tools:
    read/edit files in workdir) on a work packet. Returns immediately — poll
    openrouter_worker_check(label) every 20-30s.

    The packet must be self-contained: objective, exact file paths, pasted
    context, explicit non-goals, acceptance criteria, required report shape.
    The worker has no other context.

    isolate=True runs the worker in its own git worktree — REQUIRED when
    starting more than one worker on the same repo at once, because workers
    sharing a checkout revert each other's work. The worktree starts from HEAD
    (commit/stash first if the worker must build on uncommitted changes) and
    its path is reported by openrouter_worker_check for you to review and merge.

    run_commands=True lets it execute shell commands (tests/builds); default
    allows only file edits. Either way the worker cannot read .env/key files,
    run database or cloud CLIs, or run destructive git commands — if it reports
    being blocked on a value, supply a sanitized value in a follow-up packet.
    Pass resume_session (a session_id from a previous check result) for
    follow-up fixes in the same worker session. Requires the gateway
    (openrouter_gateway 'start' first). Always verify the resulting diff
    yourself — worker reports have understated what they changed.
    """
    if not os.path.isdir(workdir):
        return f"ERROR: workdir does not exist: {workdir}"
    label = "".join(c if c.isalnum() or c in "._-" else "-" for c in label) or "desktop"
    args = [os.path.join(SCRIPTS, "or-worker.sh"), "-d", workdir, "-l", label]
    if model:
        args += ["-m", model]
    if resume_session:
        args += ["-r", resume_session]
    if run_commands:
        args += ["-y"]
    if isolate:
        args += ["-w"]
    fd, packet_path = tempfile.mkstemp(suffix=".md", prefix=f"packet-{label}-")
    with os.fdopen(fd, "w") as f:
        f.write(packet)
    args.append(packet_path)

    os.makedirs(RUNS, exist_ok=True)
    # or-worker.sh's stdout is the final result JSON; stderr announces the log path.
    out = open(os.path.join(RUNS, f"{label}.dispatch.json"), "w")
    err = open(os.path.join(RUNS, f"{label}.dispatch.err"), "w")
    subprocess.Popen(args, stdout=out, stderr=err, start_new_session=True)
    return (
        f"worker '{label}' dispatched in {workdir}. "
        f"Poll openrouter_worker_check(label='{label}') every 20-30s until it reports a result."
    )


@mcp.tool()
def openrouter_worker_check(label: str = "desktop") -> str:
    """Check a dispatched worker. Returns the final report (with session_id for
    follow-ups, cost, turns) once done, a failure diagnosis, or RUNNING with
    its most recent activity."""
    result_path = os.path.join(RUNS, f"{label}.dispatch.json")
    err_path = os.path.join(RUNS, f"{label}.dispatch.err")

    if os.path.exists(result_path) and os.path.getsize(result_path) > 0:
        with open(result_path, errors="replace") as f:
            line = f.read().strip().splitlines()[-1]
        try:
            r = json.loads(line)
            # The worker's own report is untrusted — returning it alone would
            # hand Desktop-Claude a self-assessment and silently drop the
            # harness-collected evidence, including CRITICAL findings such as a
            # destroyed peer file. Surface both, evidence first.
            card = ""
            if os.path.exists(err_path):
                with open(err_path, errors="replace") as f:
                    err = f.read()
                if "EVIDENCE CARD" in err:
                    card = err[err.index("EVIDENCE CARD"):][:4000]
                elif "EVIDENCE UNAVAILABLE" in err:
                    card = "EVIDENCE UNAVAILABLE — nothing was verified for this run."
            return json.dumps(
                {
                    "status": r.get("subtype", "done"),
                    "evidence_card": card or "(no card — workdir is not a git repo)",
                    "evidence_verdict": (
                        "CRITICAL" if "VERDICT: CRITICAL" in card
                        else "FAIL" if "VERDICT: FAIL" in card
                        else "PASS" if "VERDICT: PASS" in card
                        else "unknown"
                    ),
                    "report_untrusted": r.get("result"),
                    "session_id": r.get("session_id"),
                    "cost_usd": r.get("total_cost_usd"),
                    "turns": r.get("num_turns"),
                },
                indent=2,
            )
        except json.JSONDecodeError:
            return f"FAILED — unparseable result: {line[:500]}"

    err_text = ""
    if os.path.exists(err_path):
        with open(err_path, errors="replace") as f:
            err_text = f.read()
    if "WORKER ERROR" in err_text or "ERROR:" in err_text:
        return f"FAILED —\n{err_text.strip()[-1500:]}"

    logs = sorted(
        glob.glob(os.path.join(RUNS, f"*-{label}-*.jsonl")), key=os.path.getmtime
    )
    if not logs:
        return "no run found yet for this label — check again in a few seconds" + (
            f"\n(dispatch stderr: {err_text.strip()[-300:]})" if err_text.strip() else ""
        )
    p = _run([os.path.join(SCRIPTS, "or-monitor.sh"), "show", logs[-1]], timeout=30)
    tail = "\n".join(p.stdout.strip().splitlines()[-8:])
    return f"RUNNING — recent activity:\n{tail}"


@mcp.tool()
def openrouter_runs_list() -> str:
    """List all worker runs with status, cost, and turn count."""
    p = _run([os.path.join(SCRIPTS, "or-monitor.sh"), "list"], timeout=30)
    return (p.stdout + p.stderr).strip()


if __name__ == "__main__":
    mcp.run()
