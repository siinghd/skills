// Run with: node --test test/gate.test.mjs
import { after, before, beforeEach, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { evaluateApproval, hashPlan, normalisePlan } from '../scripts/sdlc.mjs';
import { startStubDesk } from './stub-desk.mjs';

const SDLC = fileURLToPath(new URL('../scripts/sdlc.mjs', import.meta.url));
const WRAPPER = fileURLToPath(new URL('../scripts/sdlc.sh', import.meta.url));
const SLUG = 'demo-run';
const PLAN = '# Demo\n\nStatus: draft\n\n## Decomposition\n\n- [ ] 1. Do it\n';

let desk, root, repo, env, fakeGhDir;

function sdlc(args, { input = '', cwd = repo, extraEnv = {} } = {}) {
	return new Promise((ok) => {
		const child = spawn('node', [SDLC, ...args], { cwd, env: { ...env, ...extraEnv } });
		let stdout = '', stderr = '';
		child.stdout.on('data', (d) => (stdout += d));
		child.stderr.on('data', (d) => (stderr += d));
		child.on('close', (code) => ok({ code, stdout, stderr }));
		child.stdin.end(input);
	});
}
const git = (...args) => execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
const editAt = (rel) => sdlc(['check-edit'], { input: JSON.stringify({ cwd: repo, tool_name: 'Edit', tool_input: { file_path: join(repo, rel) } }) });
const bash = (command, opts) => sdlc(['check-ship'], { input: JSON.stringify({ cwd: repo, tool_name: 'Bash', tool_input: { command } }), ...opts });
const allowed = (r) => assert.equal(r.code, 0, `expected allow, got: ${r.stderr}`);
const denied = (r, pattern) => { assert.equal(r.code, 2, 'expected deny'); if (pattern) assert.match(r.stderr, pattern); };

function write(rel, text) {
	const file = join(repo, rel);
	mkdirSync(join(file, '..'), { recursive: true });
	writeFileSync(file, text);
}
function commitAll(msg = 'c') { git('add', '-A'); git('commit', '-qm', msg); }

/** A repo on a feature branch with a registered run, committed intent and plan. */
async function setupRun() {
	git('switch', '-qc', 'feat/demo');
	assert.equal((await sdlc(['init', SLUG])).code, 0);
	write(`docs/sdlc/${SLUG}/intent.md`, '# Intent\n');
	write(`docs/sdlc/${SLUG}/plan.md`, PLAN);
	commitAll('artifacts');
}
async function requestApproval() {
	const summary = join(root, 'summary.md');
	writeFileSync(summary, 'Short summary');
	const r = await sdlc(['request', SLUG, '--summary-file', summary]);
	assert.equal(r.code, 0, r.stderr);
	return [...desk.threads.keys()].at(-1);
}
async function approve() {
	const id = await requestApproval();
	desk.ownerPost(id, { choice: ['Approve'] });
	const r = await sdlc(['record', SLUG]);
	assert.equal(r.code, 0, r.stdout);
	return id;
}
async function passVerify() {
	const report = join(root, 'report.md');
	writeFileSync(report, 'all good');
	const r = await sdlc(['record-verify', SLUG, '--verdict', 'PASS', '--provenance', 'execution', '--report', report]);
	assert.equal(r.code, 0, r.stderr);
}

before(async () => {
	desk = await startStubDesk();
	fakeGhDir = mkdtempSync(join(tmpdir(), 'sdlc-fake-gh-'));
});
after(async () => {
	await desk.stop();
	rmSync(fakeGhDir, { recursive: true, force: true });
});
beforeEach(() => {
	root = realpathSync(mkdtempSync(join(tmpdir(), 'sdlc-test-')));
	repo = join(root, 'repo');
	mkdirSync(repo);
	env = { ...process.env, DESK_URL: desk.url, DESK_TOKEN: 'test-token' };
	git('init', '-q', '-b', 'main');
	git('config', 'user.email', 't@example.com');
	git('config', 'user.name', 'T');
	git('config', 'commit.gpgsign', 'false');
	write('src/app.txt', 'one\n');
	commitAll('base');
});

describe('plan hash', () => {
	it('ignores checkbox state and the Status line', () => {
		const ticked = PLAN.replace('- [ ] 1.', '- [x] 1.').replace('Status: draft', 'Status: in-progress');
		assert.equal(hashPlan(ticked), hashPlan(PLAN));
	});
	it('changes when the content changes', () => assert.notEqual(hashPlan(PLAN + 'more\n'), hashPlan(PLAN)));
	it('treats CRLF and LF the same', () => assert.equal(normalisePlan('a\r\nb'), 'a\nb'));
	it('only touches real checkboxes', () => assert.equal(normalisePlan('see [x] here'), 'see [x] here'));
});

describe('approval rule', () => {
	const ctx = { project: 'p', slug: 's', sha: 'a'.repeat(64) };
	const thread = (owner_posts, over = {}) => ({ id: 1, project: 'p', title: `Approve plan: s [sha:${'a'.repeat(16)}]`, status: 'open', owner_posts, ...over });
	const approve = { choice: ['Approve'], body: '', at: 'now' };

	it('accepts a last owner post of Approve', () => assert.equal(evaluateApproval(thread([approve]), ctx).approved, true));
	it('ignores thread status', () => assert.equal(evaluateApproval(thread([], { status: 'answered' }), ctx).approved, false));
	it('rejects a different project', () => assert.equal(evaluateApproval(thread([approve], { project: 'q' }), ctx).approved, false));
	it('rejects an older hash', () => assert.equal(evaluateApproval(thread([approve], { title: 'Approve plan: s [sha:bbbbbbbbbbbbbbbb]' }), ctx).approved, false));
	it('rejects another slug that contains this one', () => assert.equal(evaluateApproval(thread([approve], { title: `Approve plan: s-2 [sha:${'a'.repeat(16)}]` }), ctx).approved, false));
	it('rejects Request changes', () => assert.equal(evaluateApproval(thread([{ choice: ['Request changes'] }]), ctx).state, 'changes'));
	it('rejects Reject', () => assert.equal(evaluateApproval(thread([{ choice: ['Reject'] }]), ctx).state, 'rejected'));
	it('voids an Approve followed by a bare note', () => assert.equal(evaluateApproval(thread([approve, { choice: null, body: 'wait' }]), ctx).approved, false));
	it('accepts Approve after earlier changes', () => assert.equal(evaluateApproval(thread([{ choice: ['Request changes'] }, approve]), ctx).approved, true));
	it('rejects a multi-choice that merely includes Approve', () => assert.equal(evaluateApproval(thread([{ choice: ['Approve', 'Reject'] }]), ctx).approved, false));
});

describe('check-edit', () => {
	it('allows when the repo has no runs', async () => allowed(await editAt('src/app.txt')));

	it('allows on a branch with no run, even if other runs exist', async () => {
		await setupRun();
		git('switch', '-qc', 'hotfix/x');
		git('rm', '-qrf', '--cached', 'docs'); // keeps the files, so this branch still sees the other run
		allowed(await editAt('src/app.txt'));
	});

	it('denies a code edit before any plan exists', async () => {
		git('switch', '-qc', 'feat/demo');
		await sdlc(['init', SLUG]);
		denied(await editAt('src/app.txt'), /plan\.md/);
	});

	it('denies a code edit with a plan but no approval', async () => {
		await setupRun();
		denied(await editAt('src/app.txt'), /isn't approved/);
	});

	it('allows edits inside the run folder before approval', async () => {
		await setupRun();
		allowed(await editAt(`docs/sdlc/${SLUG}/plan.md`));
	});

	it('denies direct edits to gates.json', async () => {
		await setupRun();
		denied(await editAt(`docs/sdlc/${SLUG}/gates.json`), /only by the sdlc script/);
	});

	it('allows code edits once approved with the plan unchanged', async () => {
		await setupRun();
		await approve();
		allowed(await editAt('src/app.txt'));
	});

	it('still allows after a checkbox is ticked', async () => {
		await setupRun();
		await approve();
		write(`docs/sdlc/${SLUG}/plan.md`, PLAN.replace('- [ ] 1.', '- [x] 1.').replace('Status: draft', 'Status: in-progress'));
		allowed(await editAt('src/app.txt'));
	});

	it('denies after the plan content changes', async () => {
		await setupRun();
		await approve();
		write(`docs/sdlc/${SLUG}/plan.md`, PLAN + '\nAnother step\n');
		denied(await editAt('src/app.txt'), /changed after it was approved/);
	});

	it('allows files outside any repo', async () => {
		const r = await sdlc(['check-edit'], { input: JSON.stringify({ cwd: repo, tool_input: { file_path: join(tmpdir(), 'x', 'y.txt') } }) });
		allowed(r);
	});

	it('gates a new file in a new directory, resolving from the file path', async () => {
		await setupRun();
		denied(await editAt('src/brand/new/file.txt'));
	});

	it('resolves the repo from the file, not cwd, for a subagent in a worktree', async () => {
		await setupRun();
		const wt = join(root, 'wt');
		git('worktree', 'add', '-q', '-b', 'feat/other', wt);
		// cwd is the unrelated worktree, but the file belongs to the gated checkout.
		const r = await sdlc(['check-edit'], { input: JSON.stringify({ cwd: wt, agent_type: 'worker', tool_input: { file_path: join(repo, 'src/app.txt') } }) });
		denied(r);
	});

	it('handles notebook_path', async () => {
		await setupRun();
		denied(await sdlc(['check-edit'], { input: JSON.stringify({ cwd: repo, tool_input: { notebook_path: join(repo, 'n.ipynb') } }) }));
	});

	it('denies a malformed payload', async () => denied(await sdlc(['check-edit'], { input: 'not json' }), /fail closed/));
	it('denies a payload with no path', async () => denied(await sdlc(['check-edit'], { input: '{}' }), /fail closed/));

	it('denies when gates.json is corrupt', async () => {
		await setupRun();
		write(`docs/sdlc/${SLUG}/gates.json`, '{ nope');
		denied(await editAt('src/app.txt'), /not valid JSON/);
	});

	it('logs blocks for the review', async () => {
		await setupRun();
		await editAt('src/app.txt');
		assert.match((await sdlc(['status'])).stdout, /gate blocks logged in this clone: 1/);
	});
});

describe('check-ship', () => {
	it('ignores ordinary commands', async () => {
		await setupRun();
		allowed(await bash('npm test'));
	});

	it('allows push on a branch with no run', async () => allowed(await bash('git push origin main')));

	it('denies push with no approval', async () => {
		await setupRun();
		denied(await bash('git push -u origin feat/demo'), /isn't approved/);
	});

	it('allows push once the owner approved', async () => {
		await setupRun();
		await approve();
		allowed(await bash('git add -A && git push'));
	});

	it('denies push when only an agent "approved" in a post', async () => {
		await setupRun();
		const id = await requestApproval();
		desk.agentPost(id, { body: 'Approve' });
		denied(await bash('git push'));
	});

	it('denies push when an agent set the status to answered', async () => {
		await setupRun();
		const id = await requestApproval();
		desk.threads.get(id).status = 'answered';
		denied(await bash('git push'));
	});

	it('denies push when the owner asked for changes', async () => {
		await setupRun();
		const id = await requestApproval();
		desk.ownerPost(id, { choice: ['Request changes'], body: 'tighten scope' });
		denied(await bash('git push'), /tighten scope/);
	});

	it('denies push when the owner rejected', async () => {
		await setupRun();
		const id = await requestApproval();
		desk.ownerPost(id, { choice: ['Reject'] });
		denied(await bash('git push'), /rejected/);
	});

	it('denies push when a note follows the approval, even with a local record', async () => {
		await setupRun();
		const id = await approve();
		desk.ownerPost(id, { body: 'wait, actually' });
		denied(await bash('git push'), /wait, actually/);
		allowed(await editAt('src/app.txt')); // edits trust the local record; the push is the live check
	});

	it('catches a forged local record at push', async () => {
		await setupRun();
		const id = await requestApproval();
		// Written by hand, skipping the owner: the local edit gate is fooled, the live check isn't.
		const gatesFile = join(repo, `docs/sdlc/${SLUG}/gates.json`);
		const gates = JSON.parse(execFileSync('cat', [gatesFile], { encoding: 'utf8' }));
		gates.approval = { thread: id, sha: hashPlan(PLAN), at: 'now' };
		writeFileSync(gatesFile, JSON.stringify(gates));
		allowed(await editAt('src/app.txt'));
		denied(await bash('git push'));
	});

	it('denies reusing an approved thread after the plan changed', async () => {
		await setupRun();
		await approve();
		write(`docs/sdlc/${SLUG}/plan.md`, PLAN + 'changed\n');
		denied(await bash('git push'));
	});

	it('fails closed on push when Desk is unreachable, while edits keep working', async () => {
		await setupRun();
		await approve();
		const down = { DESK_URL: 'http://127.0.0.1:9' };
		denied(await bash('git push', { extraEnv: down }), /couldn't reach Desk/);
		const r = await sdlc(['check-edit'], { input: JSON.stringify({ cwd: repo, tool_input: { file_path: join(repo, 'src/app.txt') } }), extraEnv: down });
		allowed(r);
	});

	it('follows cd and git -C to the repo the command acts on', async () => {
		await setupRun();
		const elsewhere = sdlc(['check-ship'], { cwd: root, input: JSON.stringify({ cwd: root, tool_input: { command: `cd ${repo} && git push` } }) });
		denied(await elsewhere);
		denied(await sdlc(['check-ship'], { cwd: root, input: JSON.stringify({ cwd: root, tool_input: { command: `git -C "${repo}" push` } }) }));
	});

	it('denies PR creation with no verification', async () => {
		await setupRun();
		await approve();
		commitAll('approved');
		denied(await bash('gh pr create --fill'), /verify\.md/);
	});

	it('allows PR creation with a PASS for the current code', async () => {
		await setupRun();
		await approve();
		commitAll('approved');
		await passVerify();
		commitAll('verify'); // committing verify.md must not make it stale
		allowed(await bash('gh pr create --fill'));
	});

	it('denies PR creation when verify.md is for older code', async () => {
		await setupRun();
		await approve();
		commitAll('approved');
		await passVerify();
		write('src/app.txt', 'two\n');
		commitAll('more code');
		denied(await bash('gh pr create --fill'), /older code/);
	});

	it('denies PR creation after a FAIL', async () => {
		await setupRun();
		await approve();
		commitAll('approved');
		const report = join(root, 'r.md');
		writeFileSync(report, 'broken');
		await sdlc(['record-verify', SLUG, '--verdict', 'FAIL', '--provenance', 'execution', '--report', report]);
		denied(await bash('gh pr create --fill'), /FAIL/);
	});

	it('denies a merge from the run branch, approved or not', async () => {
		await setupRun();
		await approve();
		denied(await bash('gh pr merge --squash'), /owner's call/);
	});

	describe('merging from another branch', () => {
		function fakeGh(files) {
			const bin = join(fakeGhDir, 'gh');
			writeFileSync(bin, `#!/bin/sh\necho "$@" >> "${fakeGhDir}/gh-args"\n${files === null ? 'exit 1' : `echo '${JSON.stringify({ files: files.map((path) => ({ path })) })}'`}\n`);
			chmodSync(bin, 0o755);
			return { extraEnv: { PATH: `${fakeGhDir}:${process.env.PATH}` } };
		}
		it('denies when the PR adds a run', async () => denied(await bash('gh pr merge 12 --squash', fakeGh([`docs/sdlc/${SLUG}/gates.json`, 'src/a.ts'])), /belongs to an sdlc run/));
		it('allows when the PR has no run', async () => allowed(await bash('gh pr merge 12 --squash', fakeGh(['src/a.ts']))));
		it('fails closed when gh can\'t read the PR', async () => denied(await bash('gh pr merge 12', fakeGh(null)), /couldn't read this PR/));
	});

	it('denies a malformed payload', async () => denied(await sdlc(['check-ship'], { input: 'nope' }), /fail closed/));
});

describe('finding node', () => {
	// A PATH with git and bash but no node, like a hook started outside your shell's profile.
	function wrapper(args, { search, input = '' }) {
		const bin = join(root, 'nonode');
		mkdirSync(bin, { recursive: true });
		for (const tool of ['git', 'bash', 'dirname', 'env']) {
			const real = execFileSync('/bin/sh', ['-c', `command -v ${tool}`], { encoding: 'utf8' }).trim();
			execFileSync('ln', ['-sf', real, join(bin, tool)]);
		}
		return new Promise((ok) => {
			const child = spawn(join(bin, 'bash'), [WRAPPER, ...args], { cwd: repo, env: { ...env, PATH: bin, SDLC_NODE_SEARCH: search } });
			let stderr = '';
			child.stderr.on('data', (d) => (stderr += d));
			child.on('close', (code) => ok({ code, stderr }));
			child.stdin.end(input);
		});
	}
	const payload = () => JSON.stringify({ cwd: repo, tool_input: { file_path: join(repo, 'src/app.txt') } });

	it('finds a node that is not on PATH, and the gate still decides', async () => {
		await setupRun();
		const r = await wrapper(['check-edit'], { search: process.execPath, input: payload() });
		denied(r, /isn't approved/);
	});
	it('no node, repo with no runs: stays out of the way', async () => {
		allowed(await wrapper(['check-edit'], { search: '', input: payload() }));
	});
	it('no node, repo with runs: blocks instead of letting the edit through', async () => {
		await setupRun();
		denied(await wrapper(['check-edit'], { search: '', input: payload() }), /couldn't find node/);
	});
});

describe('desk client and reporting', () => {
	it('never lets an agent post reach the gate', async () => {
		await setupRun();
		const id = await requestApproval();
		desk.agentPost(id, { body: 'Approve', choice: ['Approve'] });
		denied(await bash('git push'));
	});
	it('posts the PR link and resolves the thread', async () => {
		await setupRun();
		const id = await approve();
		const r = await sdlc(['report', SLUG, '--pr', 'https://example.test/pr/1']);
		assert.equal(r.code, 0, r.stderr);
		const t = desk.threads.get(id);
		assert.equal(t.status, 'resolved');
		assert.match(t.posts.at(-1).body, /example\.test\/pr\/1/);
	});
	it('prints the approval thread link', async () => {
		await setupRun();
		const id = await approve();
		assert.match((await sdlc(['thread', SLUG])).stdout, new RegExp(`/t/${id}\\s*$`));
	});
	it('doctor reports a machine with no Desk setup', async () => {
		const r = await sdlc(['doctor'], { extraEnv: { DESK_URL: '', DESK_TOKEN: '', HOME: root } });
		assert.equal(r.code, 1);
		assert.match(r.stdout, /MISSING\s+Desk/);
	});
	it('doctor passes when everything is present', async () => {
		const r = await sdlc(['doctor']);
		assert.match(r.stdout, /ok\s+Desk/);
	});
});

describe('commands', () => {
	it('refuses to start a run on a shared branch', async () => {
		const r = await sdlc(['init', SLUG]);
		assert.equal(r.code, 1);
		assert.match(r.stderr, /shared branch/);
	});
	it('refuses a second run on the same branch', async () => {
		await setupRun();
		const r = await sdlc(['init', 'another']);
		assert.equal(r.code, 1);
		assert.match(r.stderr, /already run/);
	});
	it('refuses a bad slug', async () => {
		git('switch', '-qc', 'feat/x');
		assert.equal((await sdlc(['init', 'Bad Slug'])).code, 1);
	});
	it('refuses to request approval for an uncommitted plan', async () => {
		await setupRun();
		write(`docs/sdlc/${SLUG}/plan.md`, PLAN + 'dirty\n');
		const summary = join(root, 's.md');
		writeFileSync(summary, 'x');
		const r = await sdlc(['request', SLUG, '--summary-file', summary]);
		assert.equal(r.code, 1);
		assert.match(r.stderr, /commit/);
	});
	it('refuses to record when the owner has not approved', async () => {
		await setupRun();
		await requestApproval();
		const r = await sdlc(['record', SLUG]);
		assert.equal(r.code, 1);
		assert.match(r.stdout, /waiting/);
		denied(await editAt('src/app.txt'));
	});
	it('re-requests after changes, voiding the older thread', async () => {
		await setupRun();
		const first = await requestApproval();
		desk.ownerPost(first, { choice: ['Request changes'], body: 'x' });
		write(`docs/sdlc/${SLUG}/plan.md`, PLAN + 'better\n');
		commitAll('revised');
		const second = await requestApproval();
		assert.notEqual(second, first);
		desk.ownerPost(second, { choice: ['Approve'] });
		assert.equal((await sdlc(['record', SLUG])).code, 0);
		allowed(await editAt('src/app.txt'));
	});
	it('wait returns once the owner answers', async () => {
		await setupRun();
		const id = await requestApproval();
		const waiting = sdlc(['wait', SLUG, '--interval', '5']);
		desk.ownerPost(id, { choice: ['Approve'] });
		const r = await waiting;
		assert.match(r.stdout, /^approved/);
	});
	it('refuses a verdict on uncommitted code', async () => {
		await setupRun();
		write('src/app.txt', 'dirty\n');
		const report = join(root, 'r.md');
		writeFileSync(report, 'x');
		const r = await sdlc(['record-verify', SLUG, '--verdict', 'PASS', '--provenance', 'execution', '--report', report]);
		assert.equal(r.code, 1);
		assert.match(r.stderr, /commit your code/);
	});
	it('reports the round cap as its own outcome', async () => {
		await setupRun();
		const report = join(root, 'r.md');
		writeFileSync(report, 'x');
		let r;
		for (let i = 0; i < 3; i++) {
			r = await sdlc(['record-verify', SLUG, '--verdict', 'FAIL', '--provenance', 'execution', '--report', report]);
			commitAll(`round ${i}`);
		}
		assert.match(r.stdout, /round cap reached/);
	});
	it('sends a model-provenance failure to the owner', async () => {
		await setupRun();
		const report = join(root, 'r.md');
		writeFileSync(report, 'x');
		const r = await sdlc(['record-verify', SLUG, '--verdict', 'FAIL', '--provenance', 'model', '--report', report]);
		assert.match(r.stdout, /Ask the owner on Desk/);
	});
	it('status shows the stage', async () => {
		await setupRun();
		assert.match((await sdlc(['status'])).stdout, /plan written, approval not requested/);
		await approve();
		assert.match((await sdlc(['status'])).stdout, /approved, not verified/);
	});
});
