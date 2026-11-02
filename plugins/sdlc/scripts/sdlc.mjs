#!/usr/bin/env node
// sdlc: the deterministic half of the pipeline. Zero dependencies (Node 18+).
//
//   sdlc init SLUG [--project P]      register this branch as a run (docs/sdlc/SLUG/gates.json)
//   sdlc hash SLUG                    print the plan's normalised hash
//   sdlc request SLUG --summary-file F   post the plan to Desk for approval
//   sdlc wait SLUG [--interval 20]    silent until the owner answers; prints the outcome
//   sdlc record SLUG                  check Desk live and record the approval locally
//   sdlc record-verify SLUG --verdict V --provenance P --report F
//   sdlc status                       where each run stands
//   sdlc thread SLUG                  print the link to the run's approval thread
//   sdlc report SLUG --pr URL         post the PR link on the approval thread and resolve it
//   sdlc doctor                       check this machine can run the pipeline
//   sdlc check-edit                   PreToolUse hook for Edit|Write|NotebookEdit
//   sdlc check-ship                   PreToolUse hook for Bash
//
// Threat model: this stops Claude forgetting approval or taking a shortcut. It is
// not proof against a determined agent; see "What it doesn't do" in the README.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const RUNS_DIR = join('docs', 'sdlc');
const DESK = join(dirname(fileURLToPath(import.meta.url)), 'desk.mjs');
const MAX_VERIFY_ROUNDS = 3;
// Branches everyone builds on. A run here would gate all work, so init refuses them.
const SHARED_BRANCH = /^(main|master|develop|staging(-.*)?|production)$/;

// ---- errors and blocks ----

class Fail extends Error {}

/** Hook contract: exit 2 blocks the tool and shows stderr to Claude. */
function block(reason, top) {
	if (top) logBlock(top, reason);
	process.stderr.write(`BLOCKED by sdlc: ${reason}\n`);
	process.exit(2);
}

function logBlock(top, reason) {
	// The review after five runs counts these, so they outlive any one worktree.
	try {
		appendFileSync(blocksFile(top), JSON.stringify({ at: new Date().toISOString(), reason }) + '\n');
	} catch { /* losing a log line must never change the decision */ }
}

// ---- git ----

function git(cwd, ...args) {
	return execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
}
function tryGit(cwd, ...args) {
	try { return git(cwd, ...args); } catch { return null; }
}
const repoRoot = (dir) => tryGit(dir, 'rev-parse', '--show-toplevel');
const currentBranch = (top) => tryGit(top, 'branch', '--show-current') || '';
function commonDir(top) {
	const d = git(top, 'rev-parse', '--git-common-dir');
	return isAbsolute(d) ? d : resolve(top, d);
}
const blocksFile = (top) => join(commonDir(top), 'sdlc-blocks.jsonl');

// The Desk project stays the same across worktrees, whose folders have arbitrary names.
function repoName(top) {
	const d = commonDir(top);
	return basename(d) === '.git' ? basename(dirname(d)) : basename(d).replace(/\.git$/, '');
}

/** The newest commit that changed anything outside the run folder. Committing verify.md can't move it. */
function codeCommit(top, slug) {
	return git(top, 'rev-list', '-1', 'HEAD', '--', '.', `:(exclude)${RUNS_DIR}/${slug}`);
}

// ---- runs ----

const runDir = (top, slug) => join(top, RUNS_DIR, slug);
const gatesPath = (top, slug) => join(runDir(top, slug), 'gates.json');

function readGates(top, slug) {
	const file = gatesPath(top, slug);
	if (!existsSync(file)) throw new Fail(`no run named "${slug}" here (${relative(top, file)} is missing)`);
	return JSON.parse(readFileSync(file, 'utf8'));
}
function writeGates(top, slug, gates) {
	writeFileSync(gatesPath(top, slug), JSON.stringify(gates, null, 2) + '\n');
}

function allRuns(top) {
	const dir = join(top, RUNS_DIR);
	if (!existsSync(dir)) return [];
	const runs = [];
	for (const e of readdirSync(dir, { withFileTypes: true })) {
		if (!e.isDirectory() || !existsSync(gatesPath(top, e.name))) continue;
		try { runs.push({ slug: e.name, gates: readGates(top, e.name) }); }
		catch { throw new Fail(`${RUNS_DIR}/${e.name}/gates.json is not valid JSON, so the gate can't tell which run applies. Fix it from git history.`); }
	}
	return runs;
}

/** The run this branch belongs to, or null. Null is what keeps hotfixes and other worktrees ungated. */
function runForBranch(top, branch) {
	if (!branch) return null;
	const hits = allRuns(top).filter((r) => r.gates.branch === branch);
	if (hits.length > 1) throw new Fail(`runs ${hits.map((r) => r.slug).join(', ')} all claim branch ${branch}; keep one.`);
	return hits[0] || null;
}

// ---- plan hash ----

/** Ticking a checkbox or updating the Status line is progress, not a new plan, so neither voids approval. */
export function normalisePlan(text) {
	return text
		.replace(/\r\n/g, '\n')
		.split('\n')
		.filter((line) => !/^Status:/.test(line))
		.map((line) => line.replace(/^(\s*[-*] )\[[xX]\]/, '$1[ ]'))
		.join('\n');
}
export const hashPlan = (text) => createHash('sha256').update(normalisePlan(text)).digest('hex');

function planHash(top, slug) {
	const file = join(runDir(top, slug), 'plan.md');
	return existsSync(file) ? hashPlan(readFileSync(file, 'utf8')) : null;
}
const threadTitle = (slug, sha) => `Approve plan: ${slug} [sha:${sha.slice(0, 16)}]`;

// ---- the approval rule ----

/**
 * thread is desk.mjs's `get --full` summary, which keeps only posts by the owner.
 * Owner posts need a passkey session, so an agent token can't create them. thread.status
 * is deliberately ignored: agent tokens can set it to anything, including "answered".
 */
export function evaluateApproval(thread, { project, slug, sha }) {
	if (thread.project !== project) return { approved: false, state: 'mismatch', detail: `thread #${thread.id} belongs to project ${thread.project}, not ${project}` };
	if (thread.title !== threadTitle(slug, sha)) return { approved: false, state: 'mismatch', detail: `thread #${thread.id} doesn't approve this plan; the plan may have changed since it was posted` };
	const last = (thread.owner_posts || []).at(-1);
	if (!last) return { approved: false, state: 'waiting', detail: `thread #${thread.id} has no answer from the owner yet` };
	const note = last.body ? ` Note: ${last.body}` : '';
	const choice = last.choice || [];
	if (choice.length === 1 && choice[0] === 'Approve') return { approved: true, state: 'approved', detail: `approved on thread #${thread.id}.${note}`, at: last.at };
	if (choice.includes('Reject')) return { approved: false, state: 'rejected', detail: `the owner rejected this on thread #${thread.id}.${note}` };
	if (choice.includes('Request changes')) return { approved: false, state: 'changes', detail: `the owner asked for changes on thread #${thread.id}.${note}` };
	// Fails closed: "wait, actually…" after an Approve has to stop the work.
	return { approved: false, state: 'note', detail: `the owner's latest post on thread #${thread.id} isn't a tap on Approve, so it doesn't count as approval.${note}` };
}

function deskRun(args) {
	// process.execPath, not "node": sdlc.sh may have found node somewhere that isn't on PATH.
	return execFileSync(process.execPath, [DESK, ...args], { encoding: 'utf8', timeout: 20_000, stdio: ['ignore', 'pipe', 'pipe'] });
}
const fetchThread = (id) => JSON.parse(deskRun(['get', String(id)]));

/** Checks Desk now. Throws when Desk can't answer, which callers treat as "not approved". */
function liveApproval(top, slug, gates) {
	const sha = planHash(top, slug);
	if (!sha) return { approved: false, state: 'no-plan', detail: `${RUNS_DIR}/${slug}/plan.md doesn't exist yet` };
	const thread = gates.approval?.thread ?? gates.pending?.thread;
	if (!thread) return { approved: false, state: 'not-requested', detail: 'no approval has been requested yet' };
	return evaluateApproval(fetchThread(thread), { project: gates.project, slug, sha });
}

// ---- verification record ----

function readVerify(top, slug) {
	const file = join(runDir(top, slug), 'verify.md');
	if (!existsSync(file)) return null;
	const text = readFileSync(file, 'utf8');
	const field = (k) => text.match(new RegExp(`^${k}: (.+)$`, 'm'))?.[1]?.trim();
	return { verdict: field('verdict'), code: field('code') };
}
function verifyProblem(top, slug) {
	const v = readVerify(top, slug);
	if (!v) return `${RUNS_DIR}/${slug}/verify.md doesn't exist. Run the verifier and record it with: sdlc record-verify ${slug}`;
	if (!['PASS', 'PASS-WITH-NOTES'].includes(v.verdict)) return `verify.md's verdict is ${v.verdict}, not a PASS`;
	if (v.code !== codeCommit(top, slug)) return 'verify.md is for older code; verify again';
	return null;
}

// ---- hooks ----

function readPayload() {
	let raw = '';
	try { raw = readFileSync(0, 'utf8'); } catch { /* handled below */ }
	try { return JSON.parse(raw); }
	// If we can't read what's being attempted, we can't allow it.
	catch { block('unparseable hook payload; blocking to fail closed.'); }
}

/** The deepest part of the path that exists, resolved, so /tmp and /private/tmp compare equal. */
function realish(path) {
	let existing = path;
	const rest = [];
	while (!existsSync(existing)) {
		const up = dirname(existing);
		if (up === existing) return path;
		rest.unshift(basename(existing));
		existing = up;
	}
	return join(realpathSync(existing), ...rest);
}

function checkEdit() {
	const p = readPayload();
	const raw = p.tool_input?.file_path ?? p.tool_input?.notebook_path;
	if (typeof raw !== 'string' || !raw) block('this edit names no file path; blocking to fail closed.');
	const path = realish(isAbsolute(raw) ? raw : resolve(p.cwd || process.cwd(), raw));
	// Resolved from the file, not cwd: a subagent's edit may land in another worktree.
	let dir = dirname(path);
	while (!existsSync(dir)) dir = dirname(dir);
	const top = repoRoot(dir);
	if (!top) return;
	const realTop = realpathSync(top);
	// Fast path: no run folder means no process spawn beyond the one above.
	if (!existsSync(join(realTop, RUNS_DIR))) return;
	let run;
	try { run = runForBranch(realTop, currentBranch(realTop)); }
	catch (e) { block(e.message, realTop); }
	if (!run) return;

	const rel = relative(realTop, path);
	const inRun = rel.startsWith(join(RUNS_DIR, run.slug) + sep);
	if (rel === join(RUNS_DIR, run.slug, 'gates.json')) {
		block(`gates.json is written only by the sdlc script. Use: sdlc record ${run.slug}`, realTop);
	}
	if (inRun) return;

	const sha = planHash(realTop, run.slug);
	if (!sha) block(`branch ${run.gates.branch} is run "${run.slug}", and code can't change until its plan is approved. Write ${RUNS_DIR}/${run.slug}/plan.md with /sdlc:plan first.`, realTop);
	const a = run.gates.approval;
	if (!a) block(`the plan for "${run.slug}" isn't approved yet. Post it with /sdlc:plan, then wait for the owner to tap Approve on Desk.`, realTop);
	if (a.sha !== sha) block(`${RUNS_DIR}/${run.slug}/plan.md changed after it was approved, so that approval no longer counts. Post the new plan with /sdlc:plan for a fresh approval, or restore the approved text.`, realTop);
}

// Same trade-off as agent-guard.sh: this matches text, so it can over-block (echo "git push").
const IS_PUSH = /\bgit\b[^;&|]*\bpush\b/;
const IS_PR_CREATE = /\bgh\b[^;&|]*\bpr\b[^;&|]*\bcreate\b/;
const IS_PR_MERGE = /\bgh\b[^;&|]*\bpr\b[^;&|]*\bmerge\b/;

const unquote = (s) => s.replace(/^["']|["']$/g, '');

/** Where the command actually runs: `cd x && git push` and `git -C x push` both move it away from cwd. */
function commandDir(cmd, cwd) {
	const dashC = cmd.match(/\bgit\s+-C\s+("[^"]+"|'[^']+'|\S+)/);
	if (dashC) return resolve(cwd, unquote(dashC[1]));
	const cds = [...cmd.matchAll(/(?:^|[;&|]\s*)cd\s+("[^"]+"|'[^']+'|[^\s;&|]+)/g)];
	return cds.length ? resolve(cwd, unquote(cds.at(-1)[1])) : cwd;
}

/** A PR is a run's PR if it adds a run's gates.json, whichever branch this checkout happens to be on. */
function prIsRun(cmd, cwd) {
	const arg = cmd.match(/\bmerge\s+(?:-\S+\s+)*([^\s;&|-][^\s;&|]*)/)?.[1];
	const args = ['pr', 'view', ...(arg ? [unquote(arg)] : []), '--json', 'files'];
	const out = execFileSync('gh', args, { cwd, encoding: 'utf8', timeout: 20_000, stdio: ['ignore', 'pipe', 'ignore'] });
	return JSON.parse(out).files.some((f) => /^docs\/sdlc\/[^/]+\/gates\.json$/.test(f.path));
}

function checkShip() {
	const p = readPayload();
	const cmd = p.tool_input?.command;
	if (typeof cmd !== 'string') block('this Bash call has no command; blocking to fail closed.');
	const isPush = IS_PUSH.test(cmd), isCreate = IS_PR_CREATE.test(cmd), isMerge = IS_PR_MERGE.test(cmd);
	if (!isPush && !isCreate && !isMerge) return;

	const cwd = commandDir(cmd, p.cwd || process.cwd());
	const top = existsSync(cwd) ? repoRoot(cwd) : null;
	if (!top) return;
	const realTop = realpathSync(top);

	let run;
	try { run = runForBranch(realTop, currentBranch(realTop)); }
	catch (e) { block(e.message, realTop); }

	if (isMerge) {
		if (run) block('merging is the owner\'s call. Hand them the PR link.', realTop);
		let isRun;
		// Can't tell whether this PR is gated, so it stays closed.
		try { isRun = prIsRun(cmd, realTop); }
		catch { block('couldn\'t read this PR with gh, so sdlc can\'t tell whether it\'s a run\'s PR. Hand the owner the PR link.', realTop); }
		if (isRun) block('this PR belongs to an sdlc run, and merging is the owner\'s call. Hand them the PR link.', realTop);
		if (!isPush && !isCreate) return;
	}
	if (!run) return;

	let result;
	try { result = liveApproval(realTop, run.slug, run.gates); }
	catch { block(`couldn't reach Desk to confirm the plan's approval, so this stays blocked. Try again once Desk responds, or check the setup with: sdlc doctor`, realTop); }
	if (!result.approved) block(`the plan for "${run.slug}" isn't approved: ${result.detail}`, realTop);

	if (isCreate) {
		const problem = verifyProblem(realTop, run.slug);
		if (problem) block(`a PR needs a passing verification first: ${problem}`, realTop);
	}
}

// ---- commands ----

function parseFlags(args) {
	const pos = [], flags = {};
	for (let i = 0; i < args.length; i++) {
		if (args[i].startsWith('--')) flags[args[i].slice(2)] = args[++i];
		else pos.push(args[i]);
	}
	return { pos, flags };
}
function here() {
	const top = repoRoot(process.cwd());
	if (!top) throw new Fail('not inside a git repository');
	return realpathSync(top);
}
const needSlug = (pos) => pos[0] || (() => { throw new Fail('a run slug is required'); })();

function cmdInit(pos, flags) {
	const slug = needSlug(pos);
	if (!/^[a-z0-9][a-z0-9-]{0,49}$/.test(slug)) throw new Fail(`"${slug}" isn't a valid slug: lowercase letters, digits and hyphens, 50 characters at most`);
	const top = here();
	const branch = currentBranch(top);
	if (!branch) throw new Fail('HEAD is detached; switch to a feature branch first');
	const originHead = tryGit(top, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD')?.replace(/^origin\//, '');
	if (SHARED_BRANCH.test(branch) || branch === originHead) throw new Fail(`${branch} is a shared branch, and a run would gate everything on it. Create a feature branch first: git switch -c feat/${slug}`);
	const existing = runForBranch(top, branch);
	if (existing) throw new Fail(`branch ${branch} is already run "${existing.slug}"`);
	if (existsSync(gatesPath(top, slug))) throw new Fail(`run "${slug}" already exists`);
	mkdirSync(runDir(top, slug), { recursive: true });
	writeGates(top, slug, { slug, branch, project: flags.project || repoName(top), created: new Date().toISOString() });
	console.log(`run "${slug}" registered for branch ${branch}: ${RUNS_DIR}/${slug}/`);
}

function committedClean(top, rel) {
	return tryGit(top, 'ls-files', '--error-unmatch', rel) !== null && git(top, 'status', '--porcelain', '--', rel) === '';
}

function cmdRequest(pos, flags) {
	const slug = needSlug(pos), top = here(), gates = readGates(top, slug);
	const dirRel = join(RUNS_DIR, slug);
	for (const name of ['intent.md', 'plan.md']) {
		if (!committedClean(top, join(dirRel, name))) throw new Fail(`commit ${join(dirRel, name)} first; approval has to point at a committed artifact`);
	}
	if (!flags['summary-file']) throw new Fail('--summary-file is required: a few lines the owner can read on a phone');
	const sha = planHash(top, slug);
	const tmp = mkdtempSync(join(tmpdir(), 'sdlc-'));
	try {
		const body = join(tmp, 'body.md');
		writeFileSync(body, `${readFileSync(flags['summary-file'], 'utf8').trim()}\n\n**On Approve:** code edits unlock for this plan. Changing the plan later cancels the approval.\n\n**To approve:** pick Approve, then press Send. Picking it alone sends nothing. A note in that same post is fine; a separate post afterwards cancels the approval.`);
		const out = deskRun(['ask', '--project', gates.project, '--kind', 'approval', '--priority', 'high',
			'--title', threadTitle(slug, sha), '--body-file', body, '--file', join(top, dirRel, 'plan.md')]);
		const { id, url } = JSON.parse(out);
		delete gates.approval;
		gates.pending = { thread: id, sha, requested: new Date().toISOString() };
		writeGates(top, slug, gates);
		console.log(`posted for approval: ${url}`);
	} finally { rmSync(tmp, { recursive: true, force: true }); }
}

function cmdRecord(pos) {
	const slug = needSlug(pos), top = here(), gates = readGates(top, slug);
	const result = liveApproval(top, slug, gates);
	console.log(`${result.state}: ${result.detail}`);
	if (!result.approved) process.exit(1);
	const thread = gates.approval?.thread ?? gates.pending.thread;
	delete gates.pending;
	gates.approval = { thread, sha: planHash(top, slug), at: result.at };
	writeGates(top, slug, gates);
}

// Polls one thread, so unlike `desk watch` other projects' replies can't wake the session.
async function cmdWait(pos, flags) {
	const slug = needSlug(pos), top = here(), gates = readGates(top, slug);
	const every = Math.max(5, Number(flags.interval || 20)) * 1000;
	for (;;) {
		let result = null;
		try { result = liveApproval(top, slug, gates); } catch { /* Desk blipped; keep waiting */ }
		if (result && result.state !== 'waiting') { console.log(`${result.state}: ${result.detail}`); return; }
		await new Promise((r) => setTimeout(r, every));
	}
}

function cmdRecordVerify(pos, flags) {
	const slug = needSlug(pos), top = here(), gates = readGates(top, slug);
	const { verdict, provenance, report } = flags;
	if (!['PASS', 'PASS-WITH-NOTES', 'FAIL'].includes(verdict)) throw new Fail('--verdict must be PASS, PASS-WITH-NOTES or FAIL');
	if (!['execution', 'deterministic', 'model'].includes(provenance)) throw new Fail('--provenance must be execution, deterministic or model');
	if (!report || !existsSync(report)) throw new Fail('--report must name the verifier\'s report file');
	const dirty = git(top, 'status', '--porcelain', '--', '.', `:(exclude)${RUNS_DIR}/${slug}`);
	if (dirty) throw new Fail(`commit your code first; a verdict has to refer to committed code:\n${dirty}`);
	const code = codeCommit(top, slug);
	const round = (gates.verify_rounds || 0) + 1;
	gates.verify_rounds = round;
	writeGates(top, slug, gates);
	writeFileSync(join(runDir(top, slug), 'verify.md'),
		`verdict: ${verdict}\nprovenance: ${provenance}\ncode: ${code}\nround: ${round}\nat: ${new Date().toISOString()}\n\n${readFileSync(report, 'utf8')}`);
	console.log(`recorded ${verdict} (${provenance}) for ${code.slice(0, 12)}, round ${round} of ${MAX_VERIFY_ROUNDS}`);
	if (verdict !== 'FAIL') return;
	if (provenance === 'model') console.log('NEXT: model-provenance failure. Ask the owner on Desk; do not rewrite on your own reading.');
	else if (round >= MAX_VERIFY_ROUNDS) console.log('NEXT: round cap reached. This is its own outcome, not a success. Stop and report to the owner on Desk.');
	else console.log('NEXT: execution-grounded failure. Fix it and verify again.');
}

function runState(top, { slug, gates }) {
	const sha = planHash(top, slug);
	if (!sha) return 'needs a plan';
	if (gates.approval) {
		if (gates.approval.sha !== sha) return 'plan changed after approval';
		const v = readVerify(top, slug);
		if (!v) return 'approved, not verified';
		return verifyProblem(top, slug) ? `verification out of date or failing (${v.verdict})` : `verified (${v.verdict}), ready for a PR`;
	}
	if (gates.pending) return gates.pending.sha === sha ? `waiting on Desk thread #${gates.pending.thread}` : 'plan changed after it was posted';
	return 'plan written, approval not requested';
}

function cmdStatus() {
	const top = here(), branch = currentBranch(top), runs = allRuns(top);
	if (!runs.length) console.log('no runs in this checkout');
	for (const r of runs) console.log(`${r.gates.branch === branch ? '*' : ' '} ${r.slug}  [${r.gates.branch}]  ${runState(top, r)}`);
	const file = blocksFile(top);
	const blocks = existsSync(file) ? readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).length : 0;
	console.log(`gate blocks logged in this clone: ${blocks}`);
}

function runThread(gates) {
	const thread = gates.approval?.thread ?? gates.pending?.thread;
	if (!thread) throw new Fail('this run has no approval thread yet');
	return thread;
}

function cmdThread(pos) {
	const slug = needSlug(pos);
	console.log(fetchThread(runThread(readGates(here(), slug))).url);
}

function cmdReport(pos, flags) {
	const slug = needSlug(pos);
	if (!flags.pr) throw new Fail('--pr is required: the PR link');
	const thread = runThread(readGates(here(), slug));
	deskRun(['post', String(thread), '--body', `PR ready for you to review and merge: ${flags.pr}`]);
	deskRun(['resolve', String(thread)]);
	console.log(`reported on thread #${thread} and resolved it`);
}

function cmdDoctor() {
	let ok = true;
	const line = (pass, name, detail, required = true) => {
		if (!pass && required) ok = false;
		console.log(`${pass ? 'ok     ' : required ? 'MISSING' : 'warning'}  ${name}${detail ? `: ${detail}` : ''}`);
	};
	const version = (cmd) => { try { return execFileSync(cmd, ['--version'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).split('\n')[0]; } catch { return null; } };
	line(Number(process.versions.node.split('.')[0]) >= 18, 'node 18+', process.version);
	line(!!version('git'), 'git', version('git'));
	line(!!version('gh'), 'gh', version('gh') || 'needed by /sdlc:ship to open PRs', false);
	try { line(true, 'Desk', `signed in as ${JSON.parse(deskRun(['me'])).agent}`); }
	catch (e) { line(false, 'Desk', String(e.stderr || e.message).trim()); }
	process.exit(ok ? 0 : 1);
}

// Importing this file (the tests do) must not run a command.
if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
	const [cmd, ...rest] = process.argv.slice(2);
	const { pos, flags } = parseFlags(rest);
	try {
		switch (cmd) {
			case 'init': cmdInit(pos, flags); break;
			case 'hash': { const h = planHash(here(), needSlug(pos)); if (!h) throw new Fail('no plan.md'); console.log(h); break; }
			case 'request': cmdRequest(pos, flags); break;
			case 'wait': await cmdWait(pos, flags); break;
			case 'record': cmdRecord(pos); break;
			case 'record-verify': cmdRecordVerify(pos, flags); break;
			case 'status': cmdStatus(); break;
			case 'thread': cmdThread(pos); break;
			case 'report': cmdReport(pos, flags); break;
			case 'doctor': cmdDoctor(); break;
			case 'check-edit': checkEdit(); break;
			case 'check-ship': checkShip(); break;
			default:
				console.log(readFileSync(new URL(import.meta.url), 'utf8').split('\n').slice(1, 15).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
				process.exit(cmd ? 1 : 0);
		}
	} catch (e) {
		// A broken gate must not read as an allowed edit.
		if (cmd === 'check-edit' || cmd === 'check-ship') block(`the gate hit an error, so this stays blocked: ${e.message}`);
		console.error(`sdlc: ${e instanceof Fail ? e.message : e.stack}`);
		process.exit(1);
	}
}
