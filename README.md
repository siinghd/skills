# skills

Portable skills, slash commands, and agent definitions for AI coding assistants.
Everything is plain Markdown with YAML frontmatter — no tool lock-in. The repo
is the source of truth; config dirs on each machine just link to it.

## Layout

| Directory   | Contents                                              | Claude Code target   |
| ----------- | ----------------------------------------------------- | -------------------- |
| `skills/`   | One directory per skill (`SKILL.md` + optional refs)  | `~/.claude/skills`   |
| `commands/` | One Markdown file per slash command (subdirs = namespaces, e.g. `git/commit.md` → `/git:commit`) | `~/.claude/commands` |
| `agents/`   | One Markdown file per subagent definition             | `~/.claude/agents`   |

The same files work with any tool that understands Markdown + frontmatter —
point `sync.sh --target` at a different config dir to adapt.

## Setup on a new machine

```sh
git clone git@github.com:siinghd/skills.git
cd skills
./sync.sh install          # symlinks into ~/.claude (edits stay in the repo)
# or: ./sync.sh install --copy   # plain copies instead of symlinks
```

## Day-to-day sync

```sh
git pull                   # get latest (symlinked installs pick it up instantly)
./sync.sh status           # see what's linked / copied / missing
./sync.sh capture          # pull back edits made directly in ~/.claude (copy mode)
git add -A && git commit -m "update skills" && git push
```

## Adding a new skill/command/agent

Drop the file in the matching directory, commit, push, and run
`./sync.sh install` on machines using copy mode (symlink mode needs a rerun
only when a new top-level entry appears).

## OpenRouter execution tier

`skills/openrouter` + `agents/openrouter-worker.md` (driven by `/orchestrate ... use <model>`)
add a cheap delegation tier: workers on any OpenRouter-hosted model (DeepSeek,
Qwen, GLM, Kimi, …) execute mechanical packets at ~2% of premium-model rates, dispatched either as one-shot "oracles",
fully agentic headless Claude Code workers, native chaperone agents, or MCP tools
in Claude Desktop.

One-command setup on a new machine (after `./sync.sh install`):

```sh
~/.claude/skills/openrouter/setup.sh sk-or-v1-<your-openrouter-key>
```

That checks dependencies, stores the key via the platform's best backend
(macOS Keychain, Linux Secret Service if available, else a 0600 key file),
starts the local LiteLLM gateway, and registers the Claude Desktop MCP server
with the per-OS config path. Re-run any time — it's idempotent. Details in
`skills/openrouter/SKILL.md`. Works on macOS, Linux (including WSL), and
Windows under Git Bash/MSYS2 — these are bash scripts, so native
cmd.exe/PowerShell is not supported. On Windows the key file is not encrypted
at rest; WSL is the recommended route for full parity.
