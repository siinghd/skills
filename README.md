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

## OpenRouter / DeepSeek execution tier

`skills/openrouter` + `skills/orchestrate-deepseek` + `agents/deepseek-worker.md`
add a cheap delegation tier: DeepSeek workers (via OpenRouter) execute mechanical
packets at ~2% of premium-model rates, dispatched either as one-shot "oracles",
fully agentic headless Claude Code workers, native chaperone agents, or MCP tools
in Claude Desktop.

One-command setup on a new machine (after `./sync.sh install`):

```sh
~/.claude/skills/openrouter/setup.sh sk-or-v1-<your-openrouter-key>
```

That checks dependencies, stores the key in the macOS Keychain, starts the local
LiteLLM gateway, and registers the Claude Desktop MCP server. Re-run any time —
it's idempotent. Details in `skills/openrouter/SKILL.md`. macOS-only as written
(Keychain + Desktop paths); on Linux export `OPENROUTER_API_KEY` instead and
skip Desktop.
