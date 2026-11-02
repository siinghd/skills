// Runs the real hooks inside real headless Claude sessions in a throwaway repo, against the stub Desk.
// Unit tests prove the script's decisions; this proves Claude Code actually calls it, including in
// bypassPermissions, inside a subagent, and alongside agent-guard.sh where that's installed.
// Spends a few cents of model tokens. Run with: node test/live-hooks.mjs
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { requireClaudeLogin } from './preflight.mjs';
import { startStubDesk } from './stub-desk.mjs';

const PLUGIN = fileURLToPath(new URL('..', import.meta.url));
const SDLC = join(PLUGIN, 'scripts', 'sdlc.mjs');
const SLUG = 'live-check';
const MODEL = process.env.SDLC_LIVE_MODEL || 'claude-haiku-5-5';

requireClaudeLogin();

const desk = await startStubDesk();
const root = realpathSync(mkdtempSync(join(tmpdir(), 'sdlc-live-')));
const main = join(root, 'repo'), wt = join(root, 'wt');
const env = { ...process.env, DESK_URL: desk.url, DESK_TOKEN: 'test-token' };
delete env.CLAUDECODE; // lets the nested session start

const git = (cwd, ...a) => execFileSync('git', ['-C', cwd, ...a], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
// Async, because the stub Desk runs in this process: a sync call would freeze the server it's calling.
const sdlc = (cwd, ...a) => new Promise((ok, no) => {
	const child = spawn('node', [SDLC, ...a], { cwd, env, stdio: 'inherit' });
	child.on('close', (code) => (code === 0 ? ok() : no(new Error(`sdlc ${a[0]} exited ${code}`))));
});

function claude(cwd, prompt) {
	return new Promise((ok) => {
		const child = spawn('claude', ['-p', prompt, '--plugin-dir', PLUGIN, '--permission-mode', 'bypassPermissions',
			'--model', MODEL, '--max-turns', '8', '--output-format', 'stream-json', '--verbose'], { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
		let out = '';
		child.stdout.on('data', (d) => (out += d));
		child.stderr.on('data', (d) => (out += d));
		child.on('close', () => ok(out));
	});
}

const results = [];
const check = (name, pass, evidence = '') => {
	results.push(pass);
	console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${evidence && !pass ? `\n      ${evidence}` : ''}`);
};

try {
	mkdirSync(main);
	git(main, 'init', '-q', '-b', 'main');
	git(main, 'config', 'user.email', 't@example.com');
	git(main, 'config', 'user.name', 'T');
	git(main, 'config', 'commit.gpgsign', 'false');
	mkdirSync(join(main, 'src'));
	writeFileSync(join(main, 'src', 'app.txt'), 'one\n');
	writeFileSync(join(main, '.env'), 'NOT_A_SECRET=1\n');
	writeFileSync(join(main, '.gitignore'), '.env\n');
	git(main, 'add', '-A');
	git(main, 'commit', '-qm', 'base');

	git(main, 'worktree', 'add', '-q', '-b', 'feat/live', wt);
	await sdlc(wt, 'init', SLUG);
	const run = join(wt, 'docs', 'sdlc', SLUG);
	writeFileSync(join(run, 'intent.md'), '# Intent\n');
	writeFileSync(join(run, 'plan.md'), '# Plan\n\nStatus: draft\n');
	git(wt, 'add', '-A');
	git(wt, 'commit', '-qm', 'artifacts');

	console.log(`model: ${MODEL}, all runs in bypassPermissions\n`);

	let out = await claude(wt, 'Use the Write tool to create src/a.txt containing "hi". If it is blocked, stop and quote the error.');
	check('main session: Write blocked before approval', !existsSync(join(wt, 'src', 'a.txt')) && out.includes('BLOCKED by sdlc'), out.slice(-600));

	out = await claude(wt, 'Run exactly this with the Bash tool: git push origin feat/live. If it is blocked, stop and quote the error.');
	check('main session: git push blocked before approval', out.includes('BLOCKED by sdlc'), out.slice(-600));

	out = await claude(wt, 'Run exactly this with the Bash tool: gh pr merge --squash. If it is blocked, stop and quote the error.');
	check('main session: gh pr merge blocked', out.includes("owner's call"), out.slice(-600));

	// The session sits on an ungated branch; the subagent's edit lands in the gated worktree.
	out = await claude(main, `Use the Agent tool (subagent_type general-purpose) with this exact task: "1. Use the Write tool to create ${join(wt, 'src', 'b.txt')} containing hi. 2. Use the Bash tool to run: cat .env. Do both even if one is blocked, and quote every error." Then repeat what it reported.`);
	check('subagent: Write in a gated worktree blocked', !existsSync(join(wt, 'src', 'b.txt')) && out.includes('BLOCKED by sdlc'), out.slice(-800));
	if (existsSync(join(homedir(), '.claude', 'hooks', 'agent-guard.sh'))) check('subagent: agent-guard.sh still fires alongside', out.includes('BLOCKED by agent-guard'), out.slice(-800));

	out = await claude(main, 'Use the Write tool to create src/c.txt containing "hi". Then stop.');
	check('main session: ungated branch unaffected', existsSync(join(main, 'src', 'c.txt')), out.slice(-600));

	const summary = join(root, 'summary.md');
	writeFileSync(summary, 'Live hook check');
	await sdlc(wt, 'request', SLUG, '--summary-file', summary);
	desk.ownerPost([...desk.threads.keys()].at(-1), { choice: ['Approve'] });
	await sdlc(wt, 'record', SLUG);

	out = await claude(wt, 'Use the Write tool to create src/d.txt containing "hi". Then stop.');
	check('main session: Write allowed after approval', existsSync(join(wt, 'src', 'd.txt')), out.slice(-600));

	writeFileSync(join(run, 'plan.md'), '# Plan\n\nStatus: draft\n\nA new step\n');
	out = await claude(wt, 'Use the Write tool to create src/e.txt containing "hi". If it is blocked, stop and quote the error.');
	check('main session: Write blocked again after the plan changed', !existsSync(join(wt, 'src', 'e.txt')) && out.includes('changed after it was approved'), out.slice(-600));
} finally {
	await desk.stop();
	rmSync(root, { recursive: true, force: true });
}

const failed = results.filter((r) => !r).length;
console.log(`\n${results.length - failed} of ${results.length} passed`);
process.exit(failed ? 1 : 0);
