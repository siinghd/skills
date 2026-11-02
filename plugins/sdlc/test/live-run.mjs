// One whole feature through the real skills in real headless Claude sessions: intent, plan, approval,
// build, verify, PR. Throwaway repo, bare local remote, stub Desk, fake gh. The harness stands in for
// the owner by tapping Approve. Spends more tokens than live-hooks.mjs because the verifier is pinned
// to Opus. Run with: node test/live-run.mjs
import { execFileSync, spawn } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { requireClaudeLogin } from './preflight.mjs';
import { startStubDesk } from './stub-desk.mjs';

const PLUGIN = fileURLToPath(new URL('..', import.meta.url));
const SDLC = join(PLUGIN, 'scripts', 'sdlc.mjs');
const SLUG = 'greet-name';
const MODEL = process.env.SDLC_LIVE_MODEL || 'claude-sonnet-5-5';
const KEEP = process.env.SDLC_LIVE_KEEP === '1';

requireClaudeLogin();

const desk = await startStubDesk();
const root = realpathSync(mkdtempSync(join(tmpdir(), 'sdlc-run-')));
const repo = join(root, 'repo'), remote = join(root, 'remote.git'), fakeBin = join(root, 'bin'), ghLog = join(root, 'gh-args');
const env = { ...process.env, DESK_URL: desk.url, DESK_TOKEN: 'test-token', PATH: `${fakeBin}:${process.env.PATH}` };
delete env.CLAUDECODE;

const git = (...a) => execFileSync('git', ['-C', repo, ...a], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
const run = join(repo, 'docs', 'sdlc', SLUG);

function claude(prompt) {
	return new Promise((ok) => {
		const child = spawn('claude', ['-p', prompt, '--plugin-dir', PLUGIN, '--permission-mode', 'bypassPermissions',
			'--model', MODEL, '--max-turns', '40', '--output-format', 'stream-json', '--verbose'], { cwd: repo, env, stdio: ['ignore', 'pipe', 'pipe'] });
		let out = '';
		child.stdout.on('data', (d) => (out += d));
		child.stderr.on('data', (d) => (out += d));
		child.on('close', () => ok(out));
	});
}
const lastText = (out) => out.trim().split('\n').map((l) => { try { return JSON.parse(l); } catch { return {}; } }).filter((e) => e.type === 'result').at(-1)?.result ?? out.slice(-500);

const results = [];
const check = (name, pass, evidence = '') => {
	results.push(pass);
	console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${evidence && !pass ? `\n      ${String(evidence).slice(0, 900)}` : ''}`);
};

// Stands in for the owner: taps Approve on each new thread shortly after it appears.
const answered = new Set();
const owner = setInterval(() => {
	for (const [id, t] of desk.threads) {
		if (answered.has(id) || t.kind !== 'approval') continue;
		answered.add(id);
		desk.ownerPost(id, { choice: ['Approve'] });
	}
}, 2000);

try {
	mkdirSync(repo);
	mkdirSync(fakeBin);
	execFileSync('git', ['init', '-q', '--bare', '-b', 'main', remote]);
	git('init', '-q', '-b', 'main');
	git('config', 'user.email', 't@example.com');
	git('config', 'user.name', 'T');
	git('config', 'commit.gpgsign', 'false');
	writeFileSync(join(repo, 'greet.mjs'), "export const greet = () => 'hello';\n");
	writeFileSync(join(repo, 'greet.test.mjs'), "import test from 'node:test';\nimport assert from 'node:assert/strict';\nimport { greet } from './greet.mjs';\ntest('greets', () => assert.equal(greet(), 'hello'));\n");
	writeFileSync(join(repo, 'package.json'), '{ "name": "demo", "type": "module", "scripts": { "test": "node --test greet.test.mjs" } }\n');
	git('add', '-A');
	git('commit', '-qm', 'base');
	git('remote', 'add', 'origin', remote);
	git('push', '-q', '-u', 'origin', 'main');
	writeFileSync(join(fakeBin, 'gh'), `#!/bin/sh\necho "$@" >> "${ghLog}"\necho "https://example.test/pr/1"\n`);
	chmodSync(join(fakeBin, 'gh'), 0o755);

	console.log(`model: ${MODEL}\n`);
	const noQuestions = "The owner isn't available in this session and has accepted everything so far; don't ask questions.";

	let out = await claude(`/sdlc:intent Make greet() take an optional name, so greet("Ada") returns "hello Ada" and greet() still returns "hello". Use the slug ${SLUG}. ${noQuestions}`);
	check('intent: run registered on a feature branch', existsSync(join(run, 'gates.json')) && git('branch', '--show-current') !== 'main', lastText(out));
	check('intent: intent.md committed', git('ls-files', `docs/sdlc/${SLUG}/intent.md`) !== '', lastText(out));

	out = await claude(`/sdlc:plan ${SLUG} ${noQuestions}`);
	check('plan: plan.md committed', git('ls-files', `docs/sdlc/${SLUG}/plan.md`) !== '', lastText(out));
	check('plan: posted to Desk with the plan hash in the title', [...desk.threads.values()].some((t) => t.title.startsWith(`Approve plan: ${SLUG} [sha:`)), lastText(out));

	// The headless run may end while its background wait is still going; a real session would be woken.
	const status = () => execFileSync('node', [SDLC, 'status'], { cwd: repo, env, encoding: 'utf8' });
	if (!/approved|verified/.test(status())) out = await claude(`/sdlc:plan ${SLUG} Resume this run: the owner has answered on Desk. ${noQuestions}`);
	check('plan: approval recorded', JSON.parse(readFileSync(join(run, 'gates.json'), 'utf8')).approval != null, lastText(out));

	if (!readFileSync(join(repo, 'greet.mjs'), 'utf8').includes('name')) out = await claude(`/sdlc:plan ${SLUG} Resume this run and finish building it. ${noQuestions}`);
	check('build: feature written', readFileSync(join(repo, 'greet.mjs'), 'utf8').includes('name'), lastText(out));
	let testsPass = true;
	try { execFileSync('npm', ['test', '--silent'], { cwd: repo, stdio: 'ignore' }); } catch { testsPass = false; }
	check('build: tests pass', testsPass);

	out = await claude(`/sdlc:ship ${SLUG} The base branch is main. ${noQuestions}`);
	const verify = existsSync(join(run, 'verify.md')) ? readFileSync(join(run, 'verify.md'), 'utf8') : '';
	check('ship: verify.md records a PASS', /^verdict: PASS/m.test(verify), verify || lastText(out));
	check('ship: branch pushed', execFileSync('git', ['-C', remote, 'branch', '--list', git('branch', '--show-current')], { encoding: 'utf8' }).trim() !== '', lastText(out));
	const gh = existsSync(ghLog) ? readFileSync(ghLog, 'utf8') : '';
	check('ship: PR created', /pr create/.test(gh), gh || lastText(out));
	check('ship: never tried to merge', !/pr merge/.test(gh), gh);
	console.log(`\nfinal status:\n${status()}`);
} finally {
	clearInterval(owner);
	await desk.stop();
	if (KEEP) console.log(`kept: ${root}`);
	else rmSync(root, { recursive: true, force: true });
}

const failed = results.filter((r) => !r).length;
console.log(`\n${results.length - failed} of ${results.length} passed`);
process.exit(failed ? 1 : 0);
