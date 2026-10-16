/**
 * hyprmux-run.ts — runs pi's bash tool commands in Hyprmux terminals attached to pi's
 * tile (docs/AUTOMATION.md, Background jobs).
 *
 * Every command goes through `hyprmuxctl run`. It runs in a real terminal attached to
 * pi's tile, so builds and tests keep their colors and progress bars, and a prompt can
 * be answered there. pi still gets the output, as plain text, and the exit status.
 *
 * A command that ends within HYPRMUX_RUN_REVEAL_AFTER seconds (default 1.5) never
 * shows. A longer one shows as a small live preview in the tile's top-right corner:
 * click it, or press SUPER+SHIFT+B, to expand it. A success goes away after a few
 * seconds; a failure stays until you close it. Aborting the tool call closes it.
 *
 * Outside a Hyprmux terminal, or with PI_HYPRMUX_RUN=0, pi runs commands as usual.
 * Copy this file to ~/.pi/agent/extensions/.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** One word for bash: single quotes, with embedded ones closed and escaped. */
function quote(word: string): string {
	return `'${word.replace(/'/g, `'\\''`)}'`;
}

export default function (pi: ExtensionAPI) {
	if (!process.env.HYPRMUX_CLIENT || process.env.PI_HYPRMUX_RUN === "0") return;
	const ctl = process.env.HYPRMUXCTL_PATH || "hyprmuxctl";
	const reveal = process.env.HYPRMUX_RUN_REVEAL_AFTER || "1.5";

	// Rewrites the command instead of replacing the bash tool, so it composes with other
	// extensions that re-register bash (to render it differently, say).
	pi.on("tool_call", (event) => {
		if (event.toolName !== "bash") return;
		const command = event.input.command;
		if (typeof command !== "string" || command.trim() === "") return;
		event.input.command = `exec ${quote(ctl)} run --reveal-after ${quote(reveal)} -- bash -c ${quote(command)}`;
	});
}
