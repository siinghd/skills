# research skill

Autonomous ML research loop for Claude Code. Global skill; each lab repo gets its own
CLAUDE.md (budget, layout) scaffolded from `templates/`.

Start: `/research <topic>` from anywhere. The skill finds an existing lab (cwd, or
~/research/) or scaffolds one at ~/research/<topic-slug> with default budgets. Bare
`/research` continues from STATE.md.

Layout:
    SKILL.md                 the loop, ≤80 lines; auto-triggers on experiment/ablation/reproduce requests
    reference/loop.md        full protocol, step by step
    reference/hypothesis-moves.md
    reference/checklists.md  silent-bug, confound, adversarial ablation, scaling ladder, STATE.md
    reference/templates.md   log entry, FINDINGS, IDEAS, ANOMALIES, QUESTIONS, STATE, INBOX
    templates/               CLAUDE.md, PLAN.md, RESULT.md, settings.json (SessionStart hook)
    scripts/                 symlinked into each lab as bin/; each enforces one rule:
        init_lab.sh          scaffold a lab
        session_start.sh     the session ritual (runs as the SessionStart hook)
        new_experiment.sh    next NNN-slug with PLAN.md
        predict.py           log a prediction before measuring
        prereg.sh            commit PLAN.md and record its hash
        log_run.py           append runs.jsonl; refuses unregistered/edited plans
        launch.sh            background a job that survives session death
        collect.sh           harvest finished jobs; detect orphans
        finish.sh            mark a foreground-run experiment done at writeup
        report.py            the only sanctioned source of numbers; flags mismatches
        verify_result.py     every number in RESULT.md must come from report.py
        ladder.py            scaling-ladder verdict
        budget.py            compute usage vs lab.json
    ../agents/research-reviewer.md   hostile reviewer subagent (Opus)
