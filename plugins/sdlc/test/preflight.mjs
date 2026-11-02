import { execFileSync } from 'node:child_process';

/** A live test with no login would report every check as a gate failure, so it refuses to start instead. */
export function requireClaudeLogin() {
	let loggedIn = false;
	try { loggedIn = JSON.parse(execFileSync('claude', ['auth', 'status'], { encoding: 'utf8' })).loggedIn === true; } catch { /* reported below */ }
	if (loggedIn) return;
	console.error('NOT RUN: the terminal claude isn\'t logged in, so nothing was tested. Run: claude auth login');
	process.exit(3);
}
