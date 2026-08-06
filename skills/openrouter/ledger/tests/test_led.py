#!/usr/bin/env python3
"""Tests for the ledger CLI.

Run either way:
    python3 -m unittest discover -s skills/openrouter/ledger/tests -v
    python3 skills/openrouter/ledger/tests/test_led.py

The concurrency and crash tests deliberately use real OS processes rather than
threads: the workload this store exists for is N parallel agents in N separate
processes, and thread-level "concurrency" would test none of the SQLite locking
that actually matters.
"""

import json
import os
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

LEDGER_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LED = os.path.join(LEDGER_DIR, "led.py")

# Child driver for the concurrency test. Imports led.py in-process and calls
# main() in a loop: that is the CLI's real code path (a fresh connection per
# write) at the highest contention rate we can produce, without paying 1200
# interpreter startups.
CHILD_SRC = r"""
import importlib.util, sys

led_path, tag, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
spec = importlib.util.spec_from_file_location("led", led_path)
led = importlib.util.module_from_spec(spec)
spec.loader.exec_module(led)

for i in range(count):
    rc = led.main([
        "--role", "worker", "msg", "put",
        "--task", "concurrency",
        "--from", tag,
        "--kind", "status",
        "--body", "%s-%06d" % (tag, i),
    ])
    if rc != 0:
        sys.stderr.write("child %s failed at i=%d rc=%d\n" % (tag, i, rc))
        sys.exit(1)
sys.exit(0)
"""

# Writes forever so the parent can SIGKILL it at an arbitrary point, which is
# overwhelmingly likely to land inside a write transaction.
CRASH_SRC = r"""
import importlib.util, sys

led_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("led", led_path)
led = importlib.util.module_from_spec(spec)
spec.loader.exec_module(led)

i = 0
while True:
    led.main([
        "--role", "worker", "msg", "put",
        "--task", "crash", "--from", "crasher",
        "--kind", "status", "--body", "crash-%06d" % i,
    ])
    i += 1
"""


class LedgerTestCase(unittest.TestCase):
    """Gives each test its own store, and a `led` invoker bound to it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ledger-test-")
        self.addCleanup(self.tmp.cleanup)
        self.db = os.path.join(self.tmp.name, "ledger.db")
        self.env = os.environ.copy()
        self.env["LEDGER_DB"] = self.db
        # Never inherit the developer's role; every test states its own.
        self.env.pop("LEDGER_ROLE", None)

    def led(self, *args, **kwargs):
        """Invoke led.py as a real subprocess. Returns CompletedProcess."""
        env = dict(self.env)
        env.update(kwargs.pop("env_extra", {}))
        return subprocess.run(
            [sys.executable, LED] + list(args),
            env=env,
            capture_output=True,
            text=True,
            **kwargs
        )

    def led_ok(self, *args, **kwargs):
        proc = self.led(*args, **kwargs)
        self.assertEqual(
            proc.returncode, 0, "led %s failed:\n%s" % (" ".join(args), proc.stderr)
        )
        return proc

    def query(self, sql, params=()):
        """Read the store directly, out of band from the CLI."""
        conn = sqlite3.connect(self.db)
        try:
            return conn.execute(sql, params).fetchall()
        finally:
            conn.close()

    def init(self):
        return self.led_ok("--role", "orchestrator", "init")


class TestConcurrency(LedgerTestCase):
    PROCS = 12
    PER_PROC = 100

    def test_twelve_processes_write_1200_messages_with_no_losses(self):
        self.init()
        total = self.PROCS * self.PER_PROC

        children = []
        logs = []
        start = time.monotonic()
        for n in range(self.PROCS):
            # Per-child files rather than PIPEs: nothing here can deadlock on a
            # full pipe buffer while the parent is blocked in wait().
            out = open(os.path.join(self.tmp.name, "child-%d.out" % n), "w+")
            err = open(os.path.join(self.tmp.name, "child-%d.err" % n), "w+")
            logs.append((out, err))
            children.append(
                subprocess.Popen(
                    [sys.executable, "-c", CHILD_SRC, LED, "p%02d" % n, str(self.PER_PROC)],
                    env=self.env,
                    stdout=out,
                    stderr=err,
                )
            )
        codes = [c.wait() for c in children]
        elapsed = time.monotonic() - start

        stderrs = []
        for out, err in logs:
            err.seek(0)
            stderrs.append(err.read())
            out.close()
            err.close()
        joined_err = "".join(stderrs)

        self.assertEqual(codes, [0] * self.PROCS, "child failures:\n%s" % joined_err)
        self.assertNotIn("database is locked", joined_err)
        self.assertNotIn("database is busy", joined_err)
        self.assertNotIn("sqlite error", joined_err)
        # A duplicate would mean two children agreed on a body; it would also mean
        # a lost write, since the row count below would come up short.
        self.assertNotIn("duplicate idem", joined_err)

        rows = self.query("SELECT COUNT(*) FROM msg WHERE task_id='concurrency'")
        self.assertEqual(rows[0][0], total, "lost or duplicated writes")
        distinct = self.query(
            "SELECT COUNT(DISTINCT body) FROM msg WHERE task_id='concurrency'"
        )[0][0]
        self.assertEqual(distinct, total, "duplicate bodies present")
        distinct_idem = self.query(
            "SELECT COUNT(DISTINCT idem) FROM msg WHERE task_id='concurrency'"
        )[0][0]
        self.assertEqual(distinct_idem, total)
        self.assertEqual(
            self.query("SELECT COUNT(*) FROM msg WHERE idem IS NULL")[0][0], 0
        )

        rate = total / elapsed if elapsed else float("inf")
        print(
            "\n  [concurrency] %d processes x %d writes = %d rows in %.2fs "
            "=> %.0f writes/sec" % (self.PROCS, self.PER_PROC, total, elapsed, rate),
            file=sys.stderr,
        )


class TestIdempotency(LedgerTestCase):
    def test_same_explicit_idem_inserts_once_and_exits_zero_twice(self):
        self.init()
        args = (
            "--role", "worker", "msg", "put", "--task", "T", "--from", "w1",
            "--kind", "finding", "--body", "first attempt", "--idem", "fixed-key-1",
        )
        first = self.led_ok(*args)
        second = self.led_ok(*args)  # led_ok asserts exit 0 on both
        self.assertEqual(first.stdout.strip(), second.stdout.strip())
        self.assertIn("duplicate idem", second.stderr)
        self.assertEqual(self.query("SELECT COUNT(*) FROM msg")[0][0], 1)

    def test_explicit_idem_dedups_even_when_body_differs(self):
        # The idem is the caller's assertion of identity; it wins over content.
        self.init()
        base = ("--role", "worker", "msg", "put", "--task", "T", "--from", "w1", "--kind", "status")
        self.led_ok(*base, "--body", "one", "--idem", "k")
        self.led_ok(*base, "--body", "two", "--idem", "k")
        rows = self.query("SELECT body FROM msg")
        self.assertEqual([r[0] for r in rows], ["one"])


class TestIdemNotNull(LedgerTestCase):
    """Requirement: idem is NOT NULL UNIQUE and is never left to the caller.

    Chosen semantics when --idem is omitted (also documented at cmd_msg_put):
    the idem is a sha256 over the message CONTENT — task, from, to, kind,
    ref_run, body — with created_at deliberately excluded. Two byte-identical
    messages are therefore the SAME message and collapse into one row; the second
    write still exits 0 and reports the first row's id.

    The alternative (folding in a timestamp or a nonce) was rejected: it would
    mean a worker whose retry loop fires twice silently doubles its blocker in
    the channel. Duplication under retry is a worse failure than dedup under
    genuine repetition, and a caller who truly needs a distinct row can pass its
    own --idem.
    """

    def test_derived_idem_is_non_null_and_unique(self):
        self.init()
        self.led_ok(
            "--role", "worker", "msg", "put", "--task", "T", "--from", "w1",
            "--kind", "status", "--body", "alpha",
        )
        rows = self.query("SELECT idem FROM msg")
        self.assertEqual(len(rows), 1)
        idem = rows[0][0]
        self.assertIsNotNone(idem)
        self.assertEqual(len(idem), 64)
        int(idem, 16)  # hex digest, raises if not

    def test_identical_messages_without_idem_collapse_to_one_row(self):
        self.init()
        args = (
            "--role", "worker", "msg", "put", "--task", "T", "--from", "w1",
            "--kind", "blocker", "--body", "same body, no idem",
        )
        self.led_ok(*args)
        second = self.led_ok(*args)
        self.assertIn("duplicate idem", second.stderr)
        self.assertEqual(self.query("SELECT COUNT(*) FROM msg")[0][0], 1)

    def test_differing_messages_without_idem_are_distinct_rows(self):
        self.init()
        base = ("--role", "worker", "msg", "put", "--task", "T", "--from", "w1", "--kind", "status")
        self.led_ok(*base, "--body", "alpha")
        self.led_ok(*base, "--body", "beta")
        self.led_ok(*base, "--to", "w2", "--body", "alpha")  # differs only by --to
        self.assertEqual(self.query("SELECT COUNT(*) FROM msg")[0][0], 3)
        self.assertEqual(self.query("SELECT COUNT(DISTINCT idem) FROM msg")[0][0], 3)

    def test_schema_rejects_a_null_idem_written_out_of_band(self):
        # Guards the NOT NULL half of the invariant: without it, SQLite would
        # accept unlimited NULLs in the UNIQUE column and ON CONFLICT(idem) would
        # stop deduplicating without ever raising.
        self.init()
        conn = sqlite3.connect(self.db)
        try:
            with self.assertRaises(sqlite3.IntegrityError):
                conn.execute(
                    "INSERT INTO msg(task_id, from_agent, kind, body, created_at, idem) "
                    "VALUES ('T','w1','status','x',1,NULL)"
                )
        finally:
            conn.close()


class TestCrashSafety(LedgerTestCase):
    def test_sigkill_mid_write_leaves_the_store_intact(self):
        self.init()
        baseline = 25
        for i in range(baseline):
            self.led_ok(
                "--role", "worker", "msg", "put", "--task", "baseline", "--from", "w1",
                "--kind", "status", "--body", "baseline-%03d" % i,
            )

        child = subprocess.Popen(
            [sys.executable, "-c", CRASH_SRC, LED],
            env=self.env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.addCleanup(self._reap, child)

        # Wait until the victim is demonstrably writing. Reading here also proves
        # the WAL claim: this query succeeds while another process holds the
        # writer, i.e. reads do not block on writes.
        deadline = time.monotonic() + 15.0
        written = 0
        while time.monotonic() < deadline:
            written = self.query("SELECT COUNT(*) FROM msg WHERE task_id='crash'")[0][0]
            if written >= 10:
                break
            time.sleep(0.02)
        self.assertGreaterEqual(written, 10, "crash victim never started writing")

        os.kill(child.pid, signal.SIGKILL)
        self.assertEqual(child.wait(), -signal.SIGKILL)

        conn = sqlite3.connect(self.db)
        try:
            self.assertEqual(conn.execute("PRAGMA integrity_check").fetchone()[0], "ok")
            surviving = conn.execute(
                "SELECT body FROM msg WHERE task_id='baseline' ORDER BY id"
            ).fetchall()
        finally:
            conn.close()
        self.assertEqual(
            [r[0] for r in surviving], ["baseline-%03d" % i for i in range(baseline)]
        )

        # And the store is still writable afterwards — no stale lock survived.
        self.led_ok(
            "--role", "worker", "msg", "put", "--task", "baseline", "--from", "w1",
            "--kind", "status", "--body", "after-the-crash",
        )

    @staticmethod
    def _reap(child):
        if child.poll() is None:  # pragma: no cover — only if the test bailed early
            child.kill()
            child.wait()


class TestRoleEnforcement(LedgerTestCase):
    def test_worker_cannot_write_a_verdict(self):
        self.init()
        run_id = self.led_ok(
            "--role", "worker", "run", "start", "--task", "T", "--agent", "w1"
        ).stdout.strip()

        proc = self.led(
            "--role", "worker", "verdict", "put", "--task", "T", "--run", run_id,
            "--rung", "L1", "--outcome", "pass", "--provenance", "deterministic",
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("worker", proc.stderr)
        self.assertIn("verdict put", proc.stderr)
        self.assertEqual(self.query("SELECT COUNT(*) FROM verdict")[0][0], 0)

    def test_worker_role_comes_from_the_environment_by_default(self):
        self.init()
        proc = self.led(
            "verdict", "put", "--task", "T", "--run", "r", "--rung", "L0",
            "--outcome", "fail", "--provenance", "deterministic",
        )
        self.assertNotEqual(proc.returncode, 0)  # default role is worker
        self.assertEqual(self.query("SELECT COUNT(*) FROM verdict")[0][0], 0)

        proc = self.led(
            "verdict", "put", "--task", "T", "--run", "r", "--rung", "L0",
            "--outcome", "fail", "--provenance", "deterministic",
            env_extra={"LEDGER_ROLE": "orchestrator"},
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.query("SELECT COUNT(*) FROM verdict")[0][0], 1)

    def test_worker_cannot_read_verdicts_or_store_wide_stats(self):
        self.init()
        for args in (("verdict", "list", "--task", "T"), ("stats",)):
            proc = self.led("--role", "worker", *args)
            self.assertNotEqual(proc.returncode, 0, "worker should be denied %s" % (args,))
            self.assertIn("worker", proc.stderr)

    def test_worker_may_use_the_channel(self):
        self.init()
        self.led_ok(
            "--role", "worker", "msg", "put", "--task", "T", "--from", "w1",
            "--kind", "blocker", "--body", "need a decision",
        )
        self.led_ok("--role", "worker", "msg", "list", "--task", "T", "--json")


class TestSchemaGuard(LedgerTestCase):
    def test_newer_schema_version_is_refused(self):
        self.init()
        conn = sqlite3.connect(self.db)
        try:
            conn.execute("UPDATE meta SET value='999' WHERE key='schema_version'")
            conn.commit()
        finally:
            conn.close()

        for args in (
            ("--role", "orchestrator", "stats"),
            ("--role", "worker", "msg", "list", "--task", "T"),
            ("--role", "worker", "msg", "put", "--task", "T", "--from", "w1",
             "--kind", "status", "--body", "should not land"),
            ("--role", "orchestrator", "init"),
        ):
            proc = self.led(*args)
            self.assertNotEqual(proc.returncode, 0, "should refuse: %s" % (args,))
            self.assertIn("999", proc.stderr)
            self.assertIn("schema_version", proc.stderr)
        self.assertEqual(self.query("SELECT COUNT(*) FROM msg")[0][0], 0)


class TestRoundTrip(LedgerTestCase):
    def test_every_json_subcommand_round_trips(self):
        self.init()
        payload_file = os.path.join(self.tmp.name, "payload.json")
        with open(payload_file, "w", encoding="utf-8") as fh:
            json.dump({"files": ["a.ts", "b.ts"], "insertions": 12}, fh)
        signals_file = os.path.join(self.tmp.name, "signals.json")
        with open(signals_file, "w", encoding="utf-8") as fh:
            json.dump({"tests": "pass", "typecheck": "pass"}, fh)

        run_id = self.led_ok(
            "--role", "orchestrator", "run", "start", "--task", "T7", "--agent", "worker-3",
            "--model", "opus", "--role", "implementer", "--workdir", "/tmp/wt",
            "--log", "/tmp/wt/log.jsonl", "--pre", "abc123",
        ).stdout.strip()
        self.assertEqual(len(run_id), 32)

        self.led_ok(
            "--role", "orchestrator", "msg", "put", "--task", "T7", "--from", "worker-3",
            "--to", "orchestrator", "--kind", "finding", "--body", "found the bug",
            "--ref-run", run_id,
        )
        self.led_ok(
            "--role", "orchestrator", "evidence", "put", "--task", "T7", "--run", run_id,
            "--kind", "tree_diff", "--payload-file", payload_file,
        )
        self.led_ok(
            "--role", "orchestrator", "verdict", "put", "--task", "T7", "--run", run_id,
            "--rung", "L2", "--outcome", "pass", "--provenance", "model",
            "--judge-model", "opus", "--signals-file", signals_file,
        )
        self.led_ok(
            "--role", "orchestrator", "run", "end", "--run", run_id,
            "--status", "completed", "--post", "def456",
        )

        msgs = json.loads(
            self.led_ok("--role", "orchestrator", "msg", "list", "--task", "T7", "--json").stdout
        )
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["from_agent"], "worker-3")
        self.assertEqual(msgs[0]["to_agent"], "orchestrator")
        self.assertEqual(msgs[0]["kind"], "finding")
        self.assertEqual(msgs[0]["body"], "found the bug")
        self.assertEqual(msgs[0]["ref_run_id"], run_id)
        self.assertIsInstance(msgs[0]["created_at"], int)

        ev = json.loads(
            self.led_ok(
                "--role", "orchestrator", "evidence", "list", "--task", "T7", "--json"
            ).stdout
        )
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0]["run_id"], run_id)
        self.assertEqual(ev[0]["kind"], "tree_diff")
        self.assertEqual(ev[0]["payload"], {"files": ["a.ts", "b.ts"], "insertions": 12})

        vd = json.loads(
            self.led_ok(
                "--role", "orchestrator", "verdict", "list", "--task", "T7", "--json"
            ).stdout
        )
        self.assertEqual(len(vd), 1)
        self.assertEqual(vd[0]["rung"], "L2")
        self.assertEqual(vd[0]["outcome"], "pass")
        self.assertEqual(vd[0]["provenance"], "model")
        self.assertEqual(vd[0]["judge_model"], "opus")
        self.assertEqual(vd[0]["signals"], {"tests": "pass", "typecheck": "pass"})
        self.assertIsNone(vd[0]["resolved_outcome"])

        stats = json.loads(self.led_ok("--role", "orchestrator", "stats", "--json").stdout)
        self.assertEqual(stats["runs"], 1)
        self.assertEqual(stats["runs_open"], 0)
        self.assertEqual(stats["msgs"], 1)
        self.assertEqual(stats["evidence"], 1)
        self.assertEqual(stats["verdicts"], 1)
        self.assertEqual(stats["schema_version"], 1)
        self.assertEqual(stats["db"], self.db)

        run_row = self.query(
            "SELECT status, ended_at, post_tree, pre_tree, role, model FROM run"
        )[0]
        self.assertEqual(run_row[0], "completed")
        self.assertIsNotNone(run_row[1])
        self.assertEqual(run_row[2], "def456")
        self.assertEqual(run_row[3], "abc123")
        self.assertEqual(run_row[4], "implementer")
        self.assertEqual(run_row[5], "opus")

    def test_human_output_is_not_empty(self):
        self.init()
        self.led_ok(
            "--role", "orchestrator", "msg", "put", "--task", "T", "--from", "w1",
            "--kind", "status", "--body", "hello",
        )
        out = self.led_ok("--role", "orchestrator", "msg", "list", "--task", "T").stdout
        self.assertIn("hello", out)
        self.assertIn("[status]", out)
        stats_out = self.led_ok("--role", "orchestrator", "stats").stdout
        self.assertIn("msgs", stats_out)
        self.assertIn("schema_version", stats_out)

    def test_list_filters(self):
        self.init()
        base = ("--role", "orchestrator", "msg", "put", "--task", "T", "--from", "w1")
        self.led_ok(*base, "--kind", "status", "--body", "broadcast one")
        self.led_ok(*base, "--to", "w2", "--kind", "question", "--body", "for w2")
        self.led_ok(*base, "--to", "w3", "--kind", "question", "--body", "for w3")

        # --to is an inbox: direct mail plus broadcasts, never someone else's mail.
        inbox = json.loads(
            self.led_ok(
                "--role", "orchestrator", "msg", "list", "--task", "T", "--to", "w2", "--json"
            ).stdout
        )
        bodies = [m["body"] for m in inbox]
        self.assertIn("broadcast one", bodies)
        self.assertIn("for w2", bodies)
        self.assertNotIn("for w3", bodies)

        by_kind = json.loads(
            self.led_ok(
                "--role", "orchestrator", "msg", "list", "--task", "T",
                "--kind", "question", "--json",
            ).stdout
        )
        self.assertEqual(len(by_kind), 2)

        # --limit takes the most recent N, still oldest-first.
        limited = json.loads(
            self.led_ok(
                "--role", "orchestrator", "msg", "list", "--task", "T", "--limit", "2", "--json"
            ).stdout
        )
        self.assertEqual([m["body"] for m in limited], ["for w2", "for w3"])

        newest = max(m["created_at"] for m in by_kind)
        since = json.loads(
            self.led_ok(
                "--role", "orchestrator", "msg", "list", "--task", "T",
                "--since", str(newest), "--json",
            ).stdout
        )
        self.assertTrue(all(m["created_at"] >= newest for m in since))
        self.assertGreaterEqual(len(since), 1)

    def test_other_tasks_are_not_visible(self):
        self.init()
        self.led_ok(
            "--role", "orchestrator", "msg", "put", "--task", "OTHER", "--from", "w9",
            "--kind", "finding", "--body", "secret",
        )
        mine = json.loads(
            self.led_ok("--role", "worker", "msg", "list", "--task", "MINE", "--json").stdout
        )
        self.assertEqual(mine, [])


class TestLargeBody(LedgerTestCase):
    def test_one_megabyte_body_round_trips_through_stdin(self):
        self.init()
        body = ("A" * 1023 + "\n") * 1024  # exactly 1 MiB, with line structure
        self.assertEqual(len(body), 1024 * 1024)

        proc = self.led(
            "--role", "worker", "msg", "put", "--task", "BIG", "--from", "w1",
            "--kind", "handoff", "--body", "-",
            input=body,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

        rows = json.loads(
            self.led_ok("--role", "orchestrator", "msg", "list", "--task", "BIG", "--json").stdout
        )
        self.assertEqual(len(rows), 1)
        self.assertEqual(len(rows[0]["body"]), 1024 * 1024)
        self.assertEqual(rows[0]["body"], body)


class TestValidation(LedgerTestCase):
    def test_bad_enum_values_are_rejected(self):
        self.init()
        proc = self.led(
            "--role", "worker", "msg", "put", "--task", "T", "--from", "w1",
            "--kind", "gossip", "--body", "x",
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self.query("SELECT COUNT(*) FROM msg")[0][0], 0)

    def test_deterministic_verdicts_may_not_name_a_judge_model(self):
        self.init()
        proc = self.led(
            "--role", "orchestrator", "verdict", "put", "--task", "T", "--run", "r",
            "--rung", "L0", "--outcome", "pass", "--provenance", "deterministic",
            "--judge-model", "opus",
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("judge-model", proc.stderr)
        self.assertEqual(self.query("SELECT COUNT(*) FROM verdict")[0][0], 0)

    def test_non_json_payload_is_rejected(self):
        self.init()
        bad = os.path.join(self.tmp.name, "bad.json")
        with open(bad, "w", encoding="utf-8") as fh:
            fh.write("not json {")
        proc = self.led(
            "--role", "orchestrator", "evidence", "put", "--task", "T", "--run", "r",
            "--kind", "card", "--payload-file", bad,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("not valid JSON", proc.stderr)
        self.assertEqual(self.query("SELECT COUNT(*) FROM evidence")[0][0], 0)

    def test_ending_an_unknown_run_fails(self):
        self.init()
        proc = self.led("--role", "orchestrator", "run", "end", "--run", "nope", "--status", "x")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("nope", proc.stderr)


class TestStoreSetup(LedgerTestCase):
    def test_init_is_idempotent_and_sets_the_durability_pragmas(self):
        self.init()
        self.init()
        conn = sqlite3.connect(self.db)
        try:
            self.assertEqual(conn.execute("PRAGMA journal_mode").fetchone()[0].lower(), "wal")
            names = {
                r[0]
                for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                ).fetchall()
            }
        finally:
            conn.close()
        self.assertTrue({"meta", "run", "msg", "evidence", "verdict"} <= names)

    def test_a_cold_process_creates_the_store_rather_than_losing_the_message(self):
        # No `led init` here: the channel's first duty is to accept the write.
        self.assertFalse(os.path.exists(self.db))
        self.led_ok(
            "--role", "worker", "msg", "put", "--task", "T", "--from", "w1",
            "--kind", "blocker", "--body", "nobody ran init",
        )
        self.assertEqual(self.query("SELECT COUNT(*) FROM msg")[0][0], 1)

    def test_reading_a_missing_store_fails_clearly(self):
        proc = self.led("--role", "orchestrator", "msg", "list", "--task", "T")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("no ledger at", proc.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
