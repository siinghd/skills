// A local stand-in for Desk's agent API, reached through $DESK_URL. It keeps the two properties
// the gate relies on: agent routes only create agent posts, and agents can set any thread status.
import { createServer } from 'node:http';

export function startStubDesk() {
	const threads = new Map();
	let nextId = 1;

	const addPost = (t, author_type, { body = '', choice = null } = {}) =>
		t.posts.push({ author_type, body, choice: choice ? { selected: choice } : null, attachments: [], created_at: Date.now() });

	const server = createServer(async (req, res) => {
		let raw = '';
		for await (const chunk of req) raw += chunk;
		const body = raw && req.headers['content-type'] === 'application/json' ? JSON.parse(raw) : {};
		const send = (data, code = 200) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(data)); };
		const path = new URL(req.url, 'http://x').pathname;

		if (req.method === 'GET' && path === '/api/v1/me') return send({ agent: 'stub-agent' });
		if (req.method === 'POST' && path === '/api/v1/uploads') return send({ key: 'k', url: `http://localhost:${server.address().port}/put` });
		if (req.method === 'PUT' && path === '/put') return send({});
		if (req.method === 'POST' && path === '/api/v1/attachments') return send({ id: 1 });
		if (req.method === 'POST' && path === '/api/v1/threads') {
			const t = { id: nextId++, project: body.project, title: body.title, kind: body.kind, status: 'open', posts: [] };
			addPost(t, 'agent', { body: body.body });
			threads.set(t.id, t);
			return send({ id: t.id, url: `http://stub/t/${t.id}` });
		}
		const m = path.match(/^\/api\/v1\/threads\/(\d+)(\/(posts|status))?$/);
		const t = m && threads.get(Number(m[1]));
		if (m && !t) return send({ error: 'thread not found' }, 404);
		if (m && req.method === 'GET' && !m[3]) return send(t);
		if (m && req.method === 'POST' && m[3] === 'posts') { addPost(t, 'agent', { body: body.body }); return send({ id: 1 }); }
		if (m && req.method === 'POST' && m[3] === 'status') { t.status = body.status; return send({ ok: true }); }
		send({ error: 'no route' }, 404);
	});

	return new Promise((ok) => server.listen(0, '127.0.0.1', () => ok({
		url: `http://127.0.0.1:${server.address().port}`,
		threads,
		// The passkey-only route, which the tests call in the owner's place.
		ownerPost: (id, post) => addPost(threads.get(id), 'owner', post),
		agentPost: (id, post) => addPost(threads.get(id), 'agent', post),
		stop: () => new Promise((done) => server.close(done))
	})));
}
