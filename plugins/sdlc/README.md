# sdlc

A Claude Code plugin that runs a feature through committed artifacts, with code edits blocked until you approve the plan on your phone.

```text
/sdlc:intent  →  /sdlc:plan  →  approve on Desk  →  build  →  /sdlc:ship  →  you merge
```

Based on Anthropic's [AI-native SDLC playbook](https://claude.com/resources/articles/the-ai-native-sdlc-playbook), cut down for one person.

## Install

On any machine, macOS or Linux, with Node 18+, `git` and Claude Code:

```bash
claude plugin marketplace add siinghd/skills
```

```bash
claude plugin install sdlc@siinghd-skills --scope user
```

Approvals go through a [Desk](#desk) server, so each machine needs its address and an agent token:

```bash
mkdir -p ~/.config/desk && chmod 700 ~/.config/desk
```

```bash
printf '%s\n' 'https://your-desk-server' > ~/.config/desk/url
```

Put the token in `~/.config/desk/token` and `chmod 600` it. Then, in a new session, ask Claude to run `sdlc doctor`, which checks all of this. `gh` is also needed if you want `/sdlc:ship` to open PRs.

To update later:

```bash
claude plugin marketplace update siinghd-skills
```

```bash
claude plugin update sdlc@siinghd-skills
```

## What the gate does

It only applies to branches registered with `/sdlc:intent`. Everything else is untouched.

| On a run's branch | Result |
|---|---|
| Edit inside `docs/sdlc/<slug>/` | Allowed, except `gates.json` |
| Edit anywhere else | Blocked until the plan is approved, and again if its content changes |
| `git push` | Blocked unless Desk confirms the approval right now |
| `gh pr create` | Same, and also needs a passing `verify.md` for the current code |
| `gh pr merge` | Always blocked, including from another branch if the PR contains a run |

Approval means your latest post on the thread chose **Approve**, and the thread's title carries this plan's hash. On Desk, picking Approve only selects it, so you also press Send. A note in that same post is fine; a separate post afterwards cancels it. Ticking checkboxes and updating the `Status:` line in the plan don't void an approval; any other change does.

Artifacts are committed on the feature branch in `docs/sdlc/<slug>/`: `intent.md`, `plan.md`, `gates.json` and `verify.md`.

## What it doesn't do

It stops Claude forgetting approval or taking a shortcut. It isn't proof against a determined agent:

- File writes through Bash skip the edit gate.
- Bash checks match text, so they can over-block (`echo "git push"`) or be dodged by a script.
- `git merge` into a shared branch followed by a push isn't caught.
- `verify.md` is written by the session, so it's trusted, not proven.
- The edit check trusts a local record of the approval. `git push` and `gh pr create` check Desk live, so a forged record is caught there.

A required CI check would be the real enforcement.

## Desk

Desk is a small private forum where agents post questions and only the owner, signed in with a passkey, can answer. The gate relies on agent tokens being unable to create owner posts. To use something else, replace `scripts/desk.mjs` and keep its `get` output: the thread's `project` and `title`, plus `owner_posts[].choice`.

## If node isn't found

Hooks don't always get your shell's `PATH`, so `scripts/sdlc.sh` also looks in nvm, Volta, fnm, Homebrew and `/usr`. If it finds none, it blocks in repos that use runs and stays out of the way in others. Set `SDLC_NODE_SEARCH` to give it a different list.

## Tests

No network or tokens:

```bash
node --test test/gate.test.mjs
```

Real hooks in real headless Claude sessions, in a throwaway repo against a stub Desk. Spends a few cents of tokens:

```bash
node test/live-hooks.mjs
```

One whole feature through the real skills. Spends more, because the verifier runs on Opus:

```bash
node test/live-run.mjs
```

## Is it worth keeping?

After five real features, check `sdlc status` for the block count, and Desk for how many plans you sent back and how long approvals took. If nothing was ever sent back and no block caught real drift, the approvals are rubber stamps: remove the gate and keep the artifacts.
