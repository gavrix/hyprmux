/**
 * hyprmux-run.ts — runs pi's bash tool commands in Hyprmux terminals attached to pi's
 * tile (docs/AUTOMATION.md, Background jobs).
 *
 * Every command goes through `hyprmuxctl run`. It runs in a real terminal attached to
 * pi's tile, so builds and tests keep their colors and progress bars, and a prompt can
 * be answered there. pi still gets the output, as plain text, and the exit status.
 *
 * A command that ends within HYPRMUX_RUN_REVEAL_AFTER seconds (default 1.5) never
 * shows. A longer one shows as a chip in the job bar along the tile's bottom edge:
 * hover it to peek, click it or press SUPER+SHIFT+B to expand it. A success goes away after a few
 * seconds; a failure stays until you close it. Aborting the tool call closes it.
 *
 * Outside a Hyprmux terminal, with a Hyprmux that has no `hyprmuxctl run`, or with
 * PI_HYPRMUX_RUN=0, pi runs commands as usual. For commands that shouldn't block pi
 * (dev servers, watchers), the hyprmuxctl skill teaches background jobs instead.
 * Copy this file to ~/.pi/agent/extensions/.
 */

import { spawnSync } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** One word for bash: single quotes, with embedded ones closed and escaped. */
function quote(word: string): string {
	return `'${word.replace(/'/g, `'\\''`)}'`;
}

export default function (pi: ExtensionAPI) {
	if (!process.env.HYPRMUX_CLIENT || process.env.PI_HYPRMUX_RUN === "0") return;
	const ctl = process.env.HYPRMUXCTL_PATH || "hyprmuxctl";
	const reveal = process.env.HYPRMUX_RUN_REVEAL_AFTER || "1.5";
	// An older Hyprmux has no `run`: routing through it would break every command.
	if (spawnSync(ctl, ["run", "--help"], { stdio: "ignore", timeout: 2000 }).status !== 0) return;

	// Rewrites the command instead of replacing the bash tool, so it composes with other
	// extensions that re-register bash (to render it differently, say).
	pi.on("tool_call", (event) => {
		if (event.toolName !== "bash") return;
		const command = event.input.command;
		if (typeof command !== "string" || command.trim() === "") return;
		event.input.command = `exec ${quote(ctl)} run --reveal-after ${quote(reveal)} -- bash -c ${quote(command)}`;
	});
}
