#!/usr/bin/env node
// A small client for a Desk server's agent API, bundled so the plugin works on a machine with nothing else
// installed. Zero dependencies (Node 18+).
//
//   desk ask     --project P --title T --body-file F [--kind K] [--priority P] [--file PATH]
//   desk report  --project P --title T --body B
//   desk post    THREAD --body B
//   desk get     THREAD        thread summary as JSON, keeping only posts by the owner
//   desk resolve THREAD
//   desk me
//
// Token: $DESK_TOKEN or ~/.config/desk/token (chmod 600). URL: $DESK_URL or ~/.config/desk/url.
import { createReadStream, existsSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join } from 'node:path';
import { Readable } from 'node:stream';

const CONF = join(homedir(), '.config', 'desk');
const fromConf = (name) => (existsSync(join(CONF, name)) ? readFileSync(join(CONF, name), 'utf8').trim() : '');
const BASE = (process.env.DESK_URL || fromConf('url')).replace(/\/$/, '');
const TOKEN = process.env.DESK_TOKEN || fromConf('token');

function die(msg) { console.error(`desk: ${msg}`); process.exit(1); }
if (!BASE) die(`no server URL. Put it in ${join(CONF, 'url')} or set DESK_URL.`);
if (!TOKEN) die(`no token. Put one in ${join(CONF, 'token')} (chmod 600) or set DESK_TOKEN.`);

const [cmd, ...rest] = process.argv.slice(2);
const pos = [], flags = {};
for (let i = 0; i < rest.length; i++) {
	if (rest[i].startsWith('--')) flags[rest[i].slice(2)] = rest[++i];
	else pos.push(rest[i]);
}

async function call(path, body, method = body === undefined ? 'GET' : 'POST') {
	const res = await fetch(BASE + path, {
		method, headers: { Authorization: `Bearer ${TOKEN}`, ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}) },
		body: body !== undefined ? JSON.stringify(body) : undefined
	});
	const data = await res.json().catch(() => ({}));
	if (!res.ok) die(`${method} ${path} → ${res.status} ${data.error || data.message || ''}`);
	return data;
}

async function upload(file) {
	if (!existsSync(file)) die(`file not found: ${file}`);
	const filename = basename(file), size = statSync(file).size, mime = 'text/markdown';
	const { key, url } = await call('/api/v1/uploads', { filename, mime, size });
	const put = await fetch(url.startsWith('http') ? url : BASE + url, {
		method: 'PUT', headers: { 'Content-Type': mime, 'Content-Length': String(size) },
		body: Readable.toWeb(createReadStream(file)), duplex: 'half'
	});
	if (!put.ok) die(`upload of ${filename} failed (${put.status})`);
	return (await call('/api/v1/attachments', { key, filename, mime, size })).id;
}

// The approval gate reads this, so only the owner's posts may pass through it.
function summary(t) {
	const owner = t.posts.filter((p) => p.author_type === 'owner');
	return {
		id: t.id, project: t.project, title: t.title, kind: t.kind, status: t.status, url: `${BASE}/t/${t.id}`,
		owner_posts: owner.map((p) => ({ at: new Date(p.created_at).toISOString(), choice: p.choice?.selected || null, body: p.body }))
	};
}

const need = (v, what) => v || die(`${what} required`);

switch (cmd) {
	case 'me': console.log(JSON.stringify(await call('/api/v1/me'))); break;
	case 'ask': case 'report':
		console.log(JSON.stringify(await call('/api/v1/threads', {
			project: need(flags.project, '--project'), title: need(flags.title, '--title'),
			kind: cmd === 'report' ? 'report' : flags.kind || 'question', priority: flags.priority || 'normal',
			body: flags['body-file'] ? readFileSync(flags['body-file'], 'utf8') : flags.body || '',
			options: [], attachments: flags.file ? [await upload(flags.file)] : []
		})));
		break;
	case 'post': console.log(JSON.stringify(await call(`/api/v1/threads/${need(pos[0], 'THREAD')}/posts`, { body: need(flags.body, '--body'), attachments: [] }))); break;
	case 'get': console.log(JSON.stringify(summary(await call(`/api/v1/threads/${need(pos[0], 'THREAD')}`)))); break;
	case 'resolve': console.log(JSON.stringify(await call(`/api/v1/threads/${need(pos[0], 'THREAD')}/status`, { status: 'resolved' }))); break;
	default: die(`unknown command: ${cmd || '(none)'}`);
}
