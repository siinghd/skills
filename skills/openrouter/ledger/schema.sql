-- schema.sql — the ledger: a durable store that is simultaneously
--   (a) the communication channel between an orchestrator agent and its subagents, and
--   (b) the append-only record of harness-collected evidence and orchestrator verdicts.
--
-- Design constraints this schema is built around. They were measured on the
-- target machine, not assumed — do not "improve" them away:
--
--   * stdlib sqlite3 only. `sqlite3.Connection.enable_load_extension` does not
--     exist on this machine's Python (pyenv, uv-managed and system python all
--     lack it), so loadable extensions — sqlite-vec included — are impossible.
--
--   * No FTS5, even though stdlib sqlite3 has it. Its unicode61 tokenizer cannot
--     find `risk` inside `redactRiskCellsForExport` (measured: 0 hits), and raw
--     natural-language queries containing " + : or - raise OperationalError.
--     This store is addressed by exact keys — task_id, agent, kind, time ranges —
--     and must stay that way. Fuzzy retrieval belongs somewhere else, if anywhere.
--
--   * Every timestamp is INTEGER epoch milliseconds, UTC. Never a local-time
--     string: these rows are written by N concurrent OS processes and are only
--     useful if they totally order against each other.
--
-- Everything here is CREATE ... IF NOT EXISTS so that a cold process can make the
-- store ready without coordinating with its peers.

-- Store-level facts. `schema_version` is the compatibility gate: led.py refuses
-- to operate on a store whose version is newer than the code's, so an old worker
-- can never half-write a shape it does not understand.
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- One row per agent execution. `pre_tree`/`post_tree` hold the worktree hashes
-- the harness captured either side of the run — the raw material for "what did
-- this agent ACTUALLY change", as opposed to what it claimed in its report.
CREATE TABLE IF NOT EXISTS run (
  run_id     TEXT PRIMARY KEY,
  task_id    TEXT NOT NULL,
  agent      TEXT NOT NULL,   -- human label for the agent, e.g. "worker-3"
  model      TEXT,
  role       TEXT,            -- free-text role of the agent in the task
  workdir    TEXT,
  started_at INTEGER NOT NULL,
  ended_at   INTEGER,         -- NULL while the run is in flight
  status     TEXT NOT NULL,
  log_path   TEXT,
  pre_tree   TEXT,
  post_tree  TEXT
);

-- The channel. Append-only: there is no UPDATE or DELETE path in led.py, because
-- a channel an agent can rewrite is not evidence of anything.
--
-- `to_agent IS NULL` means broadcast to the whole task.
--
-- `idem` is NOT NULL UNIQUE and that combination is load-bearing: SQLite permits
-- unlimited NULLs in a UNIQUE column, so a nullable idem would make
-- `ON CONFLICT(idem) DO NOTHING` silently stop deduplicating exactly when a
-- caller omitted it. led.py therefore always supplies one, deriving a content
-- hash when the caller gives none.
CREATE TABLE IF NOT EXISTS msg (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id    TEXT NOT NULL,
  from_agent TEXT NOT NULL,
  to_agent   TEXT,
  kind       TEXT NOT NULL
             CHECK (kind IN ('question','answer','blocker','finding','status','handoff')),
  body       TEXT NOT NULL,
  ref_run_id TEXT,
  created_at INTEGER NOT NULL,
  idem       TEXT NOT NULL UNIQUE
);

-- Harness-collected facts. Never model-authored: a row here is something a tool
-- observed (a diff, a check result, a run card), which is why it is append-only
-- and carries the same idem guarantee as msg.
CREATE TABLE IF NOT EXISTS evidence (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id     TEXT,
  task_id    TEXT NOT NULL,
  kind       TEXT NOT NULL,   -- e.g. 'card', 'tree_diff', 'checks'
  payload    TEXT NOT NULL,   -- JSON, validated at write time
  created_at INTEGER NOT NULL,
  idem       TEXT NOT NULL UNIQUE
);

-- Judgments about a run. `provenance` records HOW the verdict was reached so a
-- deterministic check is never confused with a model's opinion; `judge_model`
-- must be absent for deterministic rungs, enforced below. `resolved_outcome` is
-- left NULL at write time and backfilled later with what actually turned out to
-- be true — the calibration signal for the judges.
CREATE TABLE IF NOT EXISTS verdict (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id          TEXT NOT NULL,
  run_id           TEXT,
  rung             TEXT NOT NULL CHECK (rung IN ('L0','L1','L2','L3')),
  outcome          TEXT NOT NULL CHECK (outcome IN ('pass','fail','critical','abstain')),
  signals          TEXT,       -- JSON, validated at write time
  judge_model      TEXT,       -- NULL for deterministic rungs
  provenance       TEXT NOT NULL
                   CHECK (provenance IN ('deterministic','execution','model')),
  created_at       INTEGER NOT NULL,
  resolved_outcome TEXT,
  CHECK (provenance <> 'deterministic' OR judge_model IS NULL)
);

-- Indexes follow the access paths that actually exist: "everything in this task,
-- in order" and "my inbox, in order". Nothing speculative.
CREATE INDEX IF NOT EXISTS idx_msg_task_created      ON msg(task_id, created_at);
CREATE INDEX IF NOT EXISTS idx_msg_to_created        ON msg(to_agent, created_at);
CREATE INDEX IF NOT EXISTS idx_evidence_task         ON evidence(task_id);
CREATE INDEX IF NOT EXISTS idx_verdict_task          ON verdict(task_id);
CREATE INDEX IF NOT EXISTS idx_run_task              ON run(task_id);
