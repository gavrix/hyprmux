/**
 * hyprmux.ts — tells Hyprmux what this pi session is doing (docs/AUTOMATION.md,
 * Agent state), and which session it holds so Hyprmux brings it back after a restart
 * (docs/CONFIGURATION.md, Agent sessions).
 *
 * In a Hyprmux terminal it sends one line on Hyprmux's control socket whenever that
 * changes:
 *
 *   agent {"client": <HYPRMUX_CLIENT>, "pid": <this process>, "kind": "pi",
 *          "state": "working" | "blocked" | "idle", "session": <id>, "cwd": <dir>,
 *          "file": <session file>, "message": <why it's blocked>}
 *
 * - working: from agent_start until pi settles (agent_settled, idle).
 * - blocked: while another extension says pi waits for the user, with
 *   pi.events.emit("hyprmux:blocked", { active: true, label: "Allow rm?" }) and
 *   { active: false } when answered. herdr's "herdr:blocked" works too.
 *
 * Hyprmux keeps the report while this process runs in the terminal's foreground.
 * Does nothing outside Hyprmux, or when pi runs without its terminal UI. Replaces
 * hyprmux-session.ts, which reported only the session.
 */

import net from "node:net";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type State = "working" | "blocked" | "idle";

/** One line in, one line out. Never throws; gives up after a second. */
function send(socketPath: string, line: string): Promise<void> {
	return new Promise((resolve) => {
		const socket = net.createConnection(socketPath, () => socket.end(`${line}\n`));
		const done = () => {
			clearTimeout(timer);
			socket.destroy();
			resolve();
		};
		const timer = setTimeout(done, 1000);
		timer.unref?.();
		socket.on("data", () => {});
		socket.on("error", done);
		socket.on("close", done);
	});
}

export default function hyprmux(pi: ExtensionAPI) {
	const socketPath = process.env.HYPRMUX_SOCKET;
	const client = Number(process.env.HYPRMUX_CLIENT);
	if (!socketPath || !Number.isInteger(client) || client <= 0) return;

	let ui = false;
	let working = false;
	let blocked = 0;
	let blockedLabel: string | undefined;
	let session: { session: string; cwd: string; file?: string } | undefined;
	let last: string | undefined;

	// Reports go out one at a time, and only the latest waits: a burst of changes
	// sends the last state, in order.
	let sending = false;
	let queued: string | undefined;
	const drain = async () => {
		if (sending) return;
		sending = true;
		while (queued) {
			const line = queued;
			queued = undefined;
			await send(socketPath, line);
		}
		sending = false;
	};

	const publish = (force = false) => {
		if (!ui) return;
		const state: State = blocked > 0 ? "blocked" : working ? "working" : "idle";
		const payload: Record<string, unknown> = { client, pid: process.pid, kind: "pi", state, ...session };
		if (state === "blocked" && blockedLabel) payload.message = blockedLabel;
		const line = `agent ${JSON.stringify(payload)}`;
		if (!force && line === last) return;
		last = line;
		queued = line;
		void drain();
	};

	const remember = (ctx: ExtensionContext) => {
		const id = ctx.sessionManager.getSessionId();
		if (!id) return;
		// A session with no messages has no file yet; Hyprmux skips resuming it until it does.
		const file = ctx.sessionManager.getSessionFile();
		session = { session: id, cwd: ctx.cwd || process.cwd(), ...(file ? { file } : {}) };
	};

	const onBlocked = (data: { active?: boolean; label?: string } | undefined) => {
		if (data?.active) {
			blocked += 1;
			blockedLabel = data.label;
		} else {
			blocked = Math.max(0, blocked - 1);
			if (blocked === 0) blockedLabel = undefined;
		}
		publish();
	};
	pi.events.on("hyprmux:blocked", onBlocked);
	pi.events.on("herdr:blocked", onBlocked);

	pi.on("session_start", (_event, ctx) => {
		// Only the terminal UI: print and RPC modes have no terminal to show it in.
		ui = (ctx as { mode?: string }).mode === "tui";
		remember(ctx);
		// A reload replaces the extension mid-run without another agent_start.
		working = ctx.isIdle?.() === false;
		publish(true);
	});

	pi.on("agent_start", (_event, ctx) => {
		remember(ctx);
		working = true;
		publish();
	});

	pi.on("agent_settled", (_event, ctx) => {
		if (ctx.isIdle?.() !== true) return;
		remember(ctx);
		working = false;
		publish();
	});
}
