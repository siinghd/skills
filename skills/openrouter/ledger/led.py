#!/usr/bin/env python3
"""led.py — CLI for the ledger (see schema.sql for the store's shape and rationale).

The ledger exists because a subagent currently has exactly one way to talk to its
orchestrator — a single final report — and those reports have been proven
unreliable. This gives agents a durable channel they can write to mid-run, and
gives the harness somewhere to put facts it collected itself.

Usage (the access-control --role is a TOP-LEVEL flag, before the subcommand):

  led init
  led run start --task T --agent A [--model M] [--role R] [--workdir W] [--log P] [--pre SHA]
  led run end --run R --status S [--post SHA]
  led msg put --task T --from A [--to B] --kind K --body BODY [--idem I] [--ref-run R]
  led msg list --task T [--to B] [--kind K] [--since MS] [--limit N] [--json]
  led evidence put --task T --run R --kind K --payload-file F [--idem I]
  led evidence list --task T [--kind K] [--json]
  led verdict put --task T --run R --rung L --outcome O --provenance P [--signals-file F] [--judge-model M]
  led verdict list --task T [--json]
  led stats [--json]

Note the two distinct --role flags, which the CLI contract requires both of:
  * `led --role worker|orchestrator ...` — access control (below), pre-subcommand.
  * `led run start --role R`            — free-text label stored on the run row.
Placing the access-control flag at the top level is what keeps them unambiguous.

Implementation constraints, all verified on this machine:
  * stdlib only. No third-party imports, ever.
  * No loadable extensions: sqlite3.Connection.enable_load_extension does not
    exist here. No sqlite-vec, no FTS (see schema.sql).
"""

import argparse
import contextlib
import hashlib
import json
import os
import random
import sqlite3
import sys
import time
import uuid

# The version of the store shape this code understands. Bump only alongside a
# schema change. A store reporting a HIGHER version is refused outright rather
# than written to with an older understanding of its columns.
SCHEMA_VERSION = 1

DEFAULT_DB = os.path.join(os.path.expanduser("~"), ".claude", "ledger", "ledger.db")

MSG_KINDS = ("question", "answer", "blocker", "finding", "status", "handoff")
RUNGS = ("L0", "L1", "L2", "L3")
OUTCOMES = ("pass", "fail", "critical", "abstain")
PROVENANCES = ("deterministic", "execution", "model")

ROLES = ("worker", "orchestrator")

# Access control. This is a GUARD RAIL AGAINST A CONFUSED AGENT, NOT A SECURITY
# BOUNDARY: anything that can run led.py can equally pass --role orchestrator or
# just open the SQLite file directly. Its whole job is to make a wrong action
# fail loudly and immediately instead of quietly polluting the record — a worker
# that talks itself into grading its own run should hit an error, not a row.
#
# Denied to `worker`, per operation key "<group> <verb>":
#   verdict put   — verdicts are the orchestrator's judgment; self-grading is the
#                   exact failure this store exists to make impossible.
#   verdict list  — a worker that can read its own grade has an incentive to game
#                   it. Verdicts are written about workers, not for them.
#   stats         — a cross-task global aggregate; workers are scoped to the one
#                   task they were handed.
# Everything else (init, run start/end, msg put/list, evidence put/list) is
# allowed to a worker, with the additional rule enforced in require_task() that
# every read must name an explicit --task: no cross-task listing.
WORKER_DENIED = {
    "verdict put": "workers may not write verdicts; a run does not grade itself",
    "verdict list": "workers may not read verdicts; they are written about you, not for you",
    "stats": "workers may not read store-wide stats; you are scoped to your own --task",
}


class LedError(Exception):
    """A user-facing failure. Printed to stderr; `code` becomes the exit status."""

    def __init__(self, message, code=2):
        super().__init__(message)
        self.code = code


# --------------------------------------------------------------------------
# time, identity, paths
# --------------------------------------------------------------------------


def now_ms():
    """Epoch milliseconds, UTC. The store's only notion of time."""
    return int(time.time() * 1000)


def iso(ms):
    """Render stored epoch-ms as UTC ISO-8601, for human output only."""
    if ms is None:
        return "-"
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms / 1000.0)) + ".%03dZ" % (ms % 1000)


def db_path():
    return os.environ.get("LEDGER_DB") or DEFAULT_DB


def schema_path():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.sql")


def derive_idem(*parts):
    """Content-address a row so a retried write cannot become a second row.

    Deliberately excludes created_at: two writes of the same content ARE the same
    write, whenever they happened. See the note on msg-put dedup semantics in
    cmd_msg_put.

    \\x1f (ASCII unit separator) joins the fields because it cannot occur in the
    values themselves, so ("a", "bc") can never hash equal to ("ab", "c").
    """
    joined = "\x1f".join("" if p is None else str(p) for p in parts)
    return hashlib.sha256(joined.encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------
# connection, transactions, schema gate
# --------------------------------------------------------------------------


def _is_busy(exc):
    text = str(exc).lower()
    return "locked" in text or "busy" in text


def _retry_busy(fn, attempts=8):
    """Run fn, retrying with jittered backoff while SQLite reports busy/locked.

    busy_timeout already covers the common case; this is the second line of
    defence for the real workload (N parallel agents, all writers). Every write
    this wraps is idempotent by construction — an idem UNIQUE plus ON CONFLICT
    DO NOTHING — so replaying one can never double-insert.
    """
    delay = 0.01
    for attempt in range(attempts):
        try:
            return fn()
        except sqlite3.OperationalError as exc:
            if not _is_busy(exc) or attempt == attempts - 1:
                raise
            time.sleep(delay * (0.5 + random.random()))
            delay = min(delay * 2, 0.5)


def connect(create=False):
    """Open the store with the durability pragmas the concurrent workload needs."""
    path = db_path()
    parent = os.path.dirname(path)
    if create and parent:
        os.makedirs(parent, exist_ok=True)
    if not create and not os.path.exists(path):
        raise LedError("no ledger at %s (set $LEDGER_DB or run `led init`)" % path)

    # isolation_level=None disables the sqlite3 module's implicit transaction
    # management so that every write below can use an explicit BEGIN IMMEDIATE.
    # The module's default would open DEFERRED and only take the write lock on
    # first write, which under concurrency can fail to upgrade and is not
    # retryable; IMMEDIATE takes the lock up front and honours busy_timeout.
    conn = sqlite3.connect(path, timeout=5.0, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=5000")
    # Only set journal_mode when it needs changing: on an already-WAL store this
    # avoids touching the header at all while peers are mid-write.
    if (conn.execute("PRAGMA journal_mode").fetchone()[0] or "").lower() != "wal":
        conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


@contextlib.contextmanager
def write_txn(conn):
    """A short, explicit write transaction.

    Callers MUST have finished all I/O — reading stdin, reading payload files —
    before entering. Holding the single writer lock across I/O is what turns N
    parallel agents into a queue.
    """
    _retry_busy(lambda: conn.execute("BEGIN IMMEDIATE"))
    try:
        yield
    except BaseException:
        with contextlib.suppress(sqlite3.Error):
            conn.execute("ROLLBACK")
        raise
    else:
        _retry_busy(lambda: conn.execute("COMMIT"))


def ensure_ready(conn, create_ok=True):
    """Make the store usable, then gate on its version.

    A cold process is allowed to create the schema itself rather than erroring:
    the channel's first duty is to never lose a message because setup had not
    been run yet. Every statement in schema.sql is IF NOT EXISTS, so concurrent
    processes doing this simultaneously converge instead of colliding.
    """
    have_meta = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='meta'"
    ).fetchone()
    if not have_meta:
        if not create_ok:
            raise LedError("store at %s is not a ledger (no meta table)" % db_path())
        with open(schema_path(), "r", encoding="utf-8") as fh:
            script = fh.read()
        _retry_busy(lambda: conn.executescript(script))
        with write_txn(conn):
            conn.execute(
                "INSERT OR IGNORE INTO meta(key, value) VALUES ('schema_version', ?)",
                (str(SCHEMA_VERSION),),
            )
            conn.execute(
                "INSERT OR IGNORE INTO meta(key, value) VALUES ('created_at', ?)",
                (str(now_ms()),),
            )
    check_schema_version(conn)


def check_schema_version(conn):
    """Refuse to operate on a store newer than this code understands."""
    row = conn.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
    if row is None:
        raise LedError("store at %s has no schema_version; run `led init`" % db_path())
    try:
        found = int(row[0])
    except (TypeError, ValueError):
        raise LedError("store has a non-integer schema_version %r" % (row[0],))
    if found > SCHEMA_VERSION:
        raise LedError(
            "refusing to run: ledger schema_version is %d but this led.py understands "
            "%d; upgrade led.py" % (found, SCHEMA_VERSION)
        )
    return found


def insert_dedup(conn, sql, params, table, idem):
    """Insert with ON CONFLICT(idem) DO NOTHING; return (row_id, inserted).

    On conflict the pre-existing row's id is returned, so a duplicate write is a
    successful no-op from the caller's point of view rather than an error it has
    to special-case.
    """
    with write_txn(conn):
        cur = conn.execute(sql, params)
        if cur.rowcount == 1:
            return cur.lastrowid, True
        row = conn.execute(
            "SELECT id FROM %s WHERE idem = ?" % table, (idem,)  # table is a literal
        ).fetchone()
    if row is None:  # pragma: no cover — would mean the UNIQUE index vanished
        raise LedError("write to %s was dropped and no existing row matched" % table)
    return row[0], False


# --------------------------------------------------------------------------
# input helpers (all I/O happens BEFORE any transaction opens)
# --------------------------------------------------------------------------


def read_body(value):
    """`-` means stdin, so packets can be arbitrarily large without argv limits."""
    if value == "-":
        return sys.stdin.read()
    return value


def read_json_file(path, label):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise LedError("cannot read %s %s: %s" % (label, path, exc))
    try:
        json.loads(text)
    except ValueError as exc:
        raise LedError("%s %s is not valid JSON: %s" % (label, path, exc))
    return text


def one_of(value, allowed, label):
    if value not in allowed:
        raise LedError("%s must be one of %s (got %r)" % (label, "|".join(allowed), value))
    return value


def require_task(args):
    """Workers may only read within an explicitly named task — no cross-task reads."""
    task = getattr(args, "task", None)
    if not task:
        raise LedError("--task is required")
    return task


def enforce_role(role, op):
    if role == "orchestrator":
        return
    reason = WORKER_DENIED.get(op)
    if reason:
        raise LedError(
            "role 'worker' may not run `%s`: %s "
            "(re-run as `led --role orchestrator ...` if that is genuinely your role)"
            % (op, reason)
        )


# --------------------------------------------------------------------------
# output helpers
# --------------------------------------------------------------------------


def maybe_json(text):
    """Emit stored JSON columns as JSON, not as a string-wrapped blob."""
    if text is None:
        return None
    try:
        return json.loads(text)
    except ValueError:
        return text


def emit_json(payload):
    json.dump(payload, sys.stdout, indent=2, sort_keys=False)
    sys.stdout.write("\n")


def indent_block(text):
    return "\n".join("    " + line for line in text.splitlines()) or "    "


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------


def cmd_init(args):
    conn = connect(create=True)
    try:
        ensure_ready(conn)
        version = check_schema_version(conn)
    finally:
        conn.close()
    print(db_path())
    sys.stderr.write("ledger ready (schema v%d)\n" % version)
    return 0


def cmd_run_start(args):
    run_id = uuid.uuid4().hex
    conn = connect(create=True)
    try:
        ensure_ready(conn)
        with write_txn(conn):
            conn.execute(
                "INSERT INTO run(run_id, task_id, agent, model, role, workdir, "
                "started_at, ended_at, status, log_path, pre_tree, post_tree) "
                "VALUES (?,?,?,?,?,?,?,NULL,?,?,?,NULL)",
                (
                    run_id,
                    args.task,
                    args.agent,
                    args.model,
                    args.run_role,
                    args.workdir,
                    now_ms(),
                    "running",
                    args.log,
                    args.pre,
                ),
            )
    finally:
        conn.close()
    print(run_id)
    return 0


def cmd_run_end(args):
    conn = connect(create=True)
    try:
        ensure_ready(conn)
        with write_txn(conn):
            cur = conn.execute(
                "UPDATE run SET ended_at = ?, status = ?, "
                "post_tree = COALESCE(?, post_tree) WHERE run_id = ?",
                (now_ms(), args.status, args.post, args.run),
            )
            changed = cur.rowcount
    finally:
        conn.close()
    if changed == 0:
        raise LedError("no run with run_id %r" % args.run)
    print(args.run)
    return 0


def cmd_msg_put(args):
    # Read the body first: `--body -` can be megabytes, and no transaction may be
    # open while we block on a pipe.
    body = read_body(args.body)
    kind = one_of(args.kind, MSG_KINDS, "--kind")

    # Dedup semantics when --idem is omitted, chosen deliberately:
    # the idem is a hash of (task, from, to, kind, ref_run, body) — the message's
    # CONTENT, with created_at excluded. Two identical messages therefore collapse
    # into one row; the second write succeeds (exit 0) and reports the first row's
    # id. The alternative — folding in a timestamp or nonce — would mean a worker
    # whose retry loop fires twice silently doubles its blocker in the channel,
    # and a channel that duplicates under retry is worse than one that dedups
    # under genuine repetition. If a genuinely repeated message must be distinct,
    # the caller passes an explicit --idem carrying its own nonce.
    idem = args.idem or derive_idem(
        "msg", args.task, args.from_agent, args.to_agent, kind, args.ref_run, body
    )

    conn = connect(create=True)
    try:
        ensure_ready(conn)
        row_id, inserted = insert_dedup(
            conn,
            "INSERT INTO msg(task_id, from_agent, to_agent, kind, body, ref_run_id, "
            "created_at, idem) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(idem) DO NOTHING",
            (
                args.task,
                args.from_agent,
                args.to_agent,
                kind,
                body,
                args.ref_run,
                now_ms(),
                idem,
            ),
            "msg",
            idem,
        )
    finally:
        conn.close()
    print(row_id)
    if not inserted:
        sys.stderr.write("duplicate idem; existing msg #%d left untouched\n" % row_id)
    return 0


def cmd_msg_list(args):
    task = require_task(args)
    where = ["task_id = ?"]
    params = [task]
    if args.to_agent is not None:
        # Inbox semantics: an agent's mail is what was addressed to it PLUS what
        # was broadcast to the whole task (to_agent IS NULL). Filtering on
        # equality alone would silently hide every broadcast.
        where.append("(to_agent = ? OR to_agent IS NULL)")
        params.append(args.to_agent)
    if args.kind is not None:
        where.append("kind = ?")
        params.append(one_of(args.kind, MSG_KINDS, "--kind"))
    if args.since is not None:
        where.append("created_at >= ?")  # inclusive
        params.append(args.since)

    sql = (
        "SELECT id, task_id, from_agent, to_agent, kind, body, ref_run_id, created_at, idem "
        "FROM msg WHERE " + " AND ".join(where)
    )
    if args.limit is not None:
        # --limit N means "the most recent N", but the result is still returned
        # oldest-first: a channel read wants the tail of the conversation in
        # reading order, not reversed.
        sql = (
            "SELECT * FROM (" + sql + " ORDER BY created_at DESC, id DESC LIMIT ?) "
            "ORDER BY created_at ASC, id ASC"
        )
        params.append(args.limit)
    else:
        sql += " ORDER BY created_at ASC, id ASC"

    conn = connect()
    try:
        ensure_ready(conn, create_ok=False)
        rows = conn.execute(sql, params).fetchall()
    finally:
        conn.close()

    if args.json:
        emit_json([dict(r) for r in rows])
        return 0
    for r in rows:
        print(
            "#%d %s [%s] %s -> %s (task %s)%s"
            % (
                r["id"],
                iso(r["created_at"]),
                r["kind"],
                r["from_agent"],
                r["to_agent"] or "*",
                r["task_id"],
                " ref=%s" % r["ref_run_id"] if r["ref_run_id"] else "",
            )
        )
        print(indent_block(r["body"]))
    return 0


def cmd_evidence_put(args):
    payload = read_json_file(args.payload_file, "--payload-file")
    idem = args.idem or derive_idem("evidence", args.task, args.run, args.kind, payload)
    conn = connect(create=True)
    try:
        ensure_ready(conn)
        row_id, inserted = insert_dedup(
            conn,
            "INSERT INTO evidence(run_id, task_id, kind, payload, created_at, idem) "
            "VALUES (?,?,?,?,?,?) ON CONFLICT(idem) DO NOTHING",
            (args.run, args.task, args.kind, payload, now_ms(), idem),
            "evidence",
            idem,
        )
    finally:
        conn.close()
    print(row_id)
    if not inserted:
        sys.stderr.write("duplicate idem; existing evidence #%d left untouched\n" % row_id)
    return 0


def cmd_evidence_list(args):
    task = require_task(args)
    where = ["task_id = ?"]
    params = [task]
    if args.kind is not None:
        where.append("kind = ?")
        params.append(args.kind)
    conn = connect()
    try:
        ensure_ready(conn, create_ok=False)
        rows = conn.execute(
            "SELECT id, run_id, task_id, kind, payload, created_at, idem FROM evidence "
            "WHERE " + " AND ".join(where) + " ORDER BY created_at ASC, id ASC",
            params,
        ).fetchall()
    finally:
        conn.close()

    if args.json:
        out = []
        for r in rows:
            d = dict(r)
            d["payload"] = maybe_json(d["payload"])
            out.append(d)
        emit_json(out)
        return 0
    for r in rows:
        print(
            "#%d %s [%s] run=%s task=%s"
            % (r["id"], iso(r["created_at"]), r["kind"], r["run_id"] or "-", r["task_id"])
        )
        print(indent_block(r["payload"]))
    return 0


def cmd_verdict_put(args):
    rung = one_of(args.rung, RUNGS, "--rung")
    outcome = one_of(args.outcome, OUTCOMES, "--outcome")
    provenance = one_of(args.provenance, PROVENANCES, "--provenance")
    signals = read_json_file(args.signals_file, "--signals-file") if args.signals_file else None
    if provenance == "deterministic" and args.judge_model:
        raise LedError("--judge-model is meaningless with --provenance deterministic")

    conn = connect(create=True)
    try:
        ensure_ready(conn)
        with write_txn(conn):
            cur = conn.execute(
                "INSERT INTO verdict(task_id, run_id, rung, outcome, signals, judge_model, "
                "provenance, created_at, resolved_outcome) VALUES (?,?,?,?,?,?,?,?,NULL)",
                (
                    args.task,
                    args.run,
                    rung,
                    outcome,
                    signals,
                    args.judge_model,
                    provenance,
                    now_ms(),
                ),
            )
            row_id = cur.lastrowid
    finally:
        conn.close()
    print(row_id)
    return 0


def cmd_verdict_list(args):
    task = require_task(args)
    conn = connect()
    try:
        ensure_ready(conn, create_ok=False)
        rows = conn.execute(
            "SELECT id, task_id, run_id, rung, outcome, signals, judge_model, provenance, "
            "created_at, resolved_outcome FROM verdict WHERE task_id = ? "
            "ORDER BY created_at ASC, id ASC",
            (task,),
        ).fetchall()
    finally:
        conn.close()

    if args.json:
        out = []
        for r in rows:
            d = dict(r)
            d["signals"] = maybe_json(d["signals"])
            out.append(d)
        emit_json(out)
        return 0
    for r in rows:
        print(
            "#%d %s %s %s (%s) run=%s judge=%s resolved=%s"
            % (
                r["id"],
                iso(r["created_at"]),
                r["rung"],
                r["outcome"],
                r["provenance"],
                r["run_id"] or "-",
                r["judge_model"] or "-",
                r["resolved_outcome"] or "-",
            )
        )
        if r["signals"]:
            print(indent_block(r["signals"]))
    return 0


def cmd_stats(args):
    conn = connect()
    try:
        ensure_ready(conn, create_ok=False)
        version = check_schema_version(conn)
        stats = {
            "db": db_path(),
            "schema_version": version,
            "runs": conn.execute("SELECT COUNT(*) FROM run").fetchone()[0],
            "runs_open": conn.execute(
                "SELECT COUNT(*) FROM run WHERE ended_at IS NULL"
            ).fetchone()[0],
            "msgs": conn.execute("SELECT COUNT(*) FROM msg").fetchone()[0],
            "evidence": conn.execute("SELECT COUNT(*) FROM evidence").fetchone()[0],
            "verdicts": conn.execute("SELECT COUNT(*) FROM verdict").fetchone()[0],
            "tasks": conn.execute(
                "SELECT COUNT(*) FROM (SELECT task_id FROM msg UNION "
                "SELECT task_id FROM run UNION SELECT task_id FROM evidence UNION "
                "SELECT task_id FROM verdict)"
            ).fetchone()[0],
            "msg_first_at": conn.execute("SELECT MIN(created_at) FROM msg").fetchone()[0],
            "msg_last_at": conn.execute("SELECT MAX(created_at) FROM msg").fetchone()[0],
        }
    finally:
        conn.close()
    stats["size_bytes"] = os.path.getsize(db_path()) if os.path.exists(db_path()) else 0

    if args.json:
        emit_json(stats)
        return 0
    for key, value in stats.items():
        if key.endswith("_at"):
            value = iso(value)
        print("%-16s %s" % (key, value))
    return 0


# --------------------------------------------------------------------------
# argument parsing
# --------------------------------------------------------------------------


def cmd_steps(args):
    """Compact 'what has already been done for this task' digest.

    Exists because step repetition is the single most frequent multi-agent
    failure mode (15.7% of traces): agents redo finished work because nothing
    tells them it is finished. The dispatcher injects this into each packet, so
    a worker cannot forget to ask.

    Deliberately terse — it is prepended to every packet, so its size is paid on
    every dispatch.
    """
    conn = connect()
    try:
        ensure_ready(conn, create_ok=False)
        check_schema_version(conn)
        runs = conn.execute(
            "SELECT agent, status, workdir, started_at, ended_at FROM run "
            "WHERE task_id = ? ORDER BY started_at",
            (args.task,),
        ).fetchall()
        ev = conn.execute(
            "SELECT payload FROM evidence WHERE task_id = ? AND kind = 'card' "
            "ORDER BY created_at",
            (args.task,),
        ).fetchall()
        msgs = conn.execute(
            "SELECT from_agent, kind, body FROM msg WHERE task_id = ? "
            "AND kind IN ('blocker','handoff','finding') ORDER BY created_at",
            (args.task,),
        ).fetchall()
    finally:
        conn.close()

    touched, verdicts = [], []
    for (payload,) in ev:
        try:
            card = json.loads(payload)
        except (json.JSONDecodeError, TypeError):
            continue
        touched.extend(card.get("observed") or [])
        if card.get("verdict"):
            verdicts.append(card["verdict"])

    if not runs and not touched and not msgs:
        out = ""
    else:
        lines = []
        if runs:
            done = [f"{r[0]} ({r[1]})" for r in runs]
            lines.append(f"Prior runs on this task: {', '.join(done)}")
        if touched:
            uniq = sorted(set(touched))
            shown = uniq[:25]
            more = f" (+{len(uniq) - len(shown)} more)" if len(uniq) > len(shown) else ""
            lines.append("Files ALREADY changed by earlier runs — do not redo this work:")
            lines += [f"  {p}" for p in shown]
            if more:
                lines.append(f" {more.strip()}")
        if verdicts:
            bad = [v for v in verdicts if v in ("critical", "fail")]
            if bad:
                lines.append(f"Earlier evidence verdicts needing care: {', '.join(sorted(set(bad)))}")
        for a, k, b in msgs:
            lines.append(f"{k.upper()} from {a}: {b.strip()[:240]}")
        out = "\n".join(lines)

    if getattr(args, "json", False):
        print(json.dumps({"task": args.task, "digest": out,
                          "runs": len(runs), "files": len(set(touched))}, indent=2))
    elif out:
        print(out)
    return 0


def build_parser():
    parser = argparse.ArgumentParser(
        prog="led",
        description="ledger: orchestrator<->subagent channel plus evidence/verdict record",
    )
    # Access-control role. Top-level (i.e. BEFORE the subcommand) so it cannot be
    # confused with `run start --role`, which is a free-text label on the run row.
    parser.add_argument(
        "--role",
        choices=ROLES,
        default=os.environ.get("LEDGER_ROLE") or "worker",
        help="access-control role; default $LEDGER_ROLE, else worker",
    )
    sub = parser.add_subparsers(dest="group", required=True)

    p_init = sub.add_parser("init", help="create the store if absent and report its path")
    p_init.set_defaults(op="init", func=cmd_init)

    # --- run -------------------------------------------------------------
    p_run = sub.add_parser("run", help="agent execution records")
    run_sub = p_run.add_subparsers(dest="verb", required=True)

    p_rs = run_sub.add_parser("start", help="open a run row; prints the new run_id")
    p_rs.add_argument("--task", required=True)
    p_rs.add_argument("--agent", required=True)
    p_rs.add_argument("--model")
    p_rs.add_argument(
        "--role",
        dest="run_role",
        help="free-text role label stored on the run (NOT the access-control role)",
    )
    p_rs.add_argument("--workdir")
    p_rs.add_argument("--log", help="path to this run's log file")
    p_rs.add_argument("--pre", help="pre-run worktree hash")
    p_rs.set_defaults(op="run start", func=cmd_run_start)

    p_re = run_sub.add_parser("end", help="close a run row")
    p_re.add_argument("--run", required=True)
    p_re.add_argument("--status", required=True)
    p_re.add_argument("--post", help="post-run worktree hash")
    p_re.set_defaults(op="run end", func=cmd_run_end)

    # --- msg -------------------------------------------------------------
    p_msg = sub.add_parser("msg", help="the append-only channel")
    msg_sub = p_msg.add_subparsers(dest="verb", required=True)

    p_mp = msg_sub.add_parser("put", help="append a message")
    p_mp.add_argument("--task", required=True)
    p_mp.add_argument("--from", dest="from_agent", required=True)
    p_mp.add_argument("--to", dest="to_agent", help="omit to broadcast to the task")
    p_mp.add_argument("--kind", required=True, choices=MSG_KINDS)
    p_mp.add_argument("--body", required=True, help="message body, or - to read stdin")
    p_mp.add_argument("--idem", help="explicit idempotency key; derived from content if omitted")
    p_mp.add_argument("--ref-run", dest="ref_run", help="run_id this message is about")
    p_mp.set_defaults(op="msg put", func=cmd_msg_put)

    p_ml = msg_sub.add_parser("list", help="read the channel for one task")
    p_ml.add_argument("--task", required=True)
    p_ml.add_argument("--to", dest="to_agent", help="inbox for this agent, incl. broadcasts")
    p_ml.add_argument("--kind", choices=MSG_KINDS)
    p_ml.add_argument("--since", type=int, help="epoch ms, inclusive")
    p_ml.add_argument("--limit", type=int, help="most recent N, still oldest-first")
    p_ml.add_argument("--json", action="store_true")
    p_ml.set_defaults(op="msg list", func=cmd_msg_list)

    # --- evidence --------------------------------------------------------
    p_ev = sub.add_parser("evidence", help="harness-collected facts")
    ev_sub = p_ev.add_subparsers(dest="verb", required=True)

    p_ep = ev_sub.add_parser("put", help="append an evidence row")
    p_ep.add_argument("--task", required=True)
    p_ep.add_argument("--run", required=True)
    p_ep.add_argument("--kind", required=True, help="e.g. card, tree_diff, checks")
    p_ep.add_argument("--payload-file", dest="payload_file", required=True, help="JSON file")
    p_ep.add_argument("--idem", help="explicit idempotency key; derived from content if omitted")
    p_ep.set_defaults(op="evidence put", func=cmd_evidence_put)

    p_el = ev_sub.add_parser("list", help="read evidence for one task")
    p_el.add_argument("--task", required=True)
    p_el.add_argument("--kind")
    p_el.add_argument("--json", action="store_true")
    p_el.set_defaults(op="evidence list", func=cmd_evidence_list)

    # --- verdict ---------------------------------------------------------
    p_vd = sub.add_parser("verdict", help="judgments about a run (orchestrator only)")
    vd_sub = p_vd.add_subparsers(dest="verb", required=True)

    p_vp = vd_sub.add_parser("put", help="record a verdict")
    p_vp.add_argument("--task", required=True)
    p_vp.add_argument("--run", required=True)
    p_vp.add_argument("--rung", required=True, choices=RUNGS)
    p_vp.add_argument("--outcome", required=True, choices=OUTCOMES)
    p_vp.add_argument("--provenance", required=True, choices=PROVENANCES)
    p_vp.add_argument("--signals-file", dest="signals_file", help="JSON file")
    p_vp.add_argument("--judge-model", dest="judge_model")
    p_vp.set_defaults(op="verdict put", func=cmd_verdict_put)

    p_vl = vd_sub.add_parser("list", help="read verdicts for one task")
    p_vl.add_argument("--task", required=True)
    p_vl.add_argument("--json", action="store_true")
    p_vl.set_defaults(op="verdict list", func=cmd_verdict_list)

    # --- stats -----------------------------------------------------------
    p_st = sub.add_parser("stats", help="store-wide counts (orchestrator only)")
    p_st.add_argument("--json", action="store_true")
    p_st.set_defaults(op="stats", func=cmd_stats)

    p_sp = sub.add_parser(
        "steps", help="digest of work already done for a task (injected into packets)"
    )
    p_sp.add_argument("--task", required=True)
    p_sp.add_argument("--json", action="store_true")
    p_sp.set_defaults(op="steps", func=cmd_steps)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        enforce_role(args.role, args.op)
        return args.func(args)
    except LedError as exc:
        sys.stderr.write("led: %s\n" % exc)
        return exc.code
    except sqlite3.Error as exc:
        sys.stderr.write("led: sqlite error: %s\n" % exc)
        return 3
    except BrokenPipeError:  # pragma: no cover — `led msg list | head`
        return 0


if __name__ == "__main__":
    sys.exit(main())
