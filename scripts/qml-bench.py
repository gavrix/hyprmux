#!/usr/bin/env python3
"""Load test for the QML host (plans: phase 4). Starts a throwaway Hyprmux with the
built-in sysload plugin and the QML Stress app (clients/qml/bench), runs each load
scenario, and reports how it renders and what it costs.

    HYPRMUX_APP=/tmp/HyprmuxTest.app scripts/bundle.sh   # once, a test copy
    scripts/qml-bench.py [--app APP] [--seconds N] [--json FILE] [scenario ...]

Scenarios: startup, idle, full, hidden, scene, hidden-scene, gpu, list, resize,
plugin. Default: all.

Frames flow only while the throwaway Hyprmux's window is on screen, on the current
Space: keep it there for the run (about two minutes), or pass --front. It leaves your own Hyprmux
alone: its own instance name, socket, config, and session.

Numbers per scenario:
- fps: frames Hyprmux showed per second.
- render: the host's CPU time per frame (polish, sync, render), avg and p95 ms.
- submit: endFrame, which for an offscreen frame waits for the GPU to finish it.
- finish: QRhi::finish after that, any GPU wait left.
- callback: commit to frame callback, how long Hyprmux took to show a frame.
- configure: a resize's configure to the commit answering it (resize only).
- app cpu, hyprmux cpu: percent of one core over the run.
- memory: the app's physical footprint at the end. Its graphics part, as
  `footprint` reports it, swings with GPU driver memory macOS reclaims later.
- buffers, metal: what the host itself holds: the IOSurfaces Hyprmux shows, and
  every Metal allocation, those buffers' textures included. These are steady.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STRESS = ROOT / "clients/qml/bench/Stress.hmapp"
ALL = ["startup", "idle", "full", "hidden", "scene", "hidden-scene", "gpu", "list", "resize", "plugin"]


class Bench:
    def __init__(self, app: Path, seconds: float, front: bool):
        self.app = app
        self.front = front
        self.seconds = seconds
        self.ctl = app / "Contents/MacOS/hyprmuxctl"
        self.work = Path(tempfile.mkdtemp(prefix="hm-qml-bench."))
        self.stats = self.work / "stats.jsonl"
        self.env = dict(os.environ, HYPRMUX_SOCKET=str(self.work / "hyprmux.sock"))
        self.hyprmux_pid = None
        self.results = {}
        self.workspace = "1"

    # MARK: Hyprmux

    def run(self, *args, check=True, timeout=30):
        p = subprocess.run([str(self.ctl), *args], env=self.env, capture_output=True, text=True, timeout=timeout)
        if check and p.returncode != 0:
            raise RuntimeError(f"hyprmuxctl {' '.join(args)}: {p.stderr.strip() or p.stdout.strip()}")
        return p.stdout

    def surfaces(self):
        return json.loads(self.run("surfaces"))

    def wait(self, what, test, timeout=15):
        end = time.time() + timeout
        while time.time() < end:
            try:
                v = test()
                if v:
                    return v
            except (RuntimeError, json.JSONDecodeError, subprocess.TimeoutExpired):
                pass
            time.sleep(0.2)
        raise RuntimeError(f"timed out waiting for {what}")

    def start(self):
        (self.work / "apps").mkdir()
        shutil.copytree(STRESS, self.work / "apps" / STRESS.name)
        (self.work / "hyprmux.conf").write_text("plugin = sysload\ninput:follow_mouse = 0\n")
        subprocess.run(["open", *([] if self.front else ["-g"]), "-n",
                        "--env", "HYPRMUX_INSTANCE=qml-bench",
                        "--env", f"HYPRMUX_SOCKET={self.env['HYPRMUX_SOCKET']}",
                        "--env", f"HYPRMUX_CONFIG={self.work / 'hyprmux.conf'}",
                        "--env", f"HYPRMUX_CHROMIUM_PROFILE={self.work / 'chromium'}",
                        "--env", f"HYPRMUX_SESSION={self.work / 'session.json'}",
                        "--env", f"HM_QML_STATS={self.stats}",
                        str(self.app)], check=True)
        plugins = self.wait("Hyprmux", lambda: json.loads(self.run("plugins")))
        pid = self.wait("sysload", lambda: next((p.get("pid") for p in json.loads(self.run("plugins"))["plugins"]
                                                 if p.get("state") == "running"), None))
        self.plugin_pid = pid
        self.hyprmux_pid = int(subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True,
                                              text=True).stdout.strip())
        self.run("apps", "refresh")

    def stop(self):
        if self.hyprmux_pid:
            subprocess.run(["kill", str(self.hyprmux_pid)], capture_output=True)
        shutil.rmtree(self.work, ignore_errors=True)

    # MARK: Measuring

    @staticmethod
    def cpu_seconds(pid):
        out = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        if not out:
            return None
        parts = [float(p) for p in re.split(r"[:]", out)]
        secs = 0.0
        for p in parts:
            secs = secs * 60 + p
        return secs

    @staticmethod
    def footprint(pid):
        """(total, graphics) physical footprint in MB."""
        with tempfile.NamedTemporaryFile(suffix=".json") as f:
            subprocess.run(["footprint", "-j", f.name, str(pid)], capture_output=True)
            try:
                d = json.load(open(f.name))
            except (json.JSONDecodeError, OSError):
                return None, None
        proc = d["processes"][0]
        # IOSurfaces and Metal memory count as "graphics" categories.
        graphics = sum(c.get("dirty", 0) for name, c in proc.get("categories", {}).items()
                       if "graphics" in name or name.startswith("IOAccelerator") or name.startswith("IOSurface"))
        return proc["footprint"] / 2**20, graphics / 2**20

    def stats_for(self, pid, since, until, role="toplevel"):
        lines = []
        if self.stats.exists():
            for line in self.stats.read_text().splitlines():
                try:
                    o = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if o.get("pid") == pid and o.get("role") == role and since <= o.get("t", 0) <= until:
                    lines.append(o)
        return lines

    @staticmethod
    def merge(lines, key):
        """Weighted avg, worst p95, and max of one timing over many seconds."""
        parts = [l[key] for l in lines if l.get(key, {}).get("n", 0) > 0]
        n = sum(p["n"] for p in parts)
        if n == 0:
            return None
        return {"avg": round(sum(p["avg"] * p["n"] for p in parts) / n, 2),
                "p95": max(p["p95"] for p in parts), "max": max(p["max"] for p in parts), "n": n}

    def measure(self, name, pid, surface_id, role="toplevel", during=None):
        """Measures `self.seconds` of a running scenario. `during` runs meanwhile."""
        def shown():
            s = next((s for s in self.surfaces() if s["id"] == surface_id), None)
            return s.get("framesShown", 0) if s else 0

        start = time.time()
        cpu0, hcpu0, shown0 = self.cpu_seconds(pid), self.cpu_seconds(self.hyprmux_pid), shown() if surface_id else 0
        if during:
            during(start + self.seconds)
        else:
            time.sleep(self.seconds)
        end = time.time()
        cpu1, hcpu1, shown1 = self.cpu_seconds(pid), self.cpu_seconds(self.hyprmux_pid), shown() if surface_id else 0
        wall = end - start
        lines = self.stats_for(pid, start + 0.5, end + 0.5, role)
        total, graphics = self.footprint(pid)
        r = {
            "seconds": round(wall, 1),
            "fps": round((shown1 - shown0) / wall, 1) if surface_id else None,
            "host_frames": sum(l["frames"] for l in lines),
            "starved": sum(l["starved"] for l in lines),
            "configures": sum(l["configures"] for l in lines),
            "render": self.merge(lines, "render"),
            "submit": self.merge(lines, "submit"),
            "gpu_wait": self.merge(lines, "gpu_wait"),
            "interval": self.merge(lines, "interval"),
            "callback": self.merge(lines, "callback"),
            "configure": self.merge(lines, "configure"),
            "app_cpu": round(100 * (cpu1 - cpu0) / wall, 1) if cpu0 is not None and cpu1 is not None else None,
            "hyprmux_cpu": round(100 * (hcpu1 - hcpu0) / wall, 1),
            "memory_mb": round(total, 1) if total else None,
            "graphics_mb": round(graphics, 1) if graphics else None,
            # The host's own allocations, at their largest: buffers Hyprmux shows,
            # and all Metal memory (which includes those buffers' textures).
            "surfaces_mb": max((l.get("surfaces_mb", 0) for l in lines), default=None),
            "metal_mb": max((l.get("metal_mb", 0) for l in lines), default=None),
        }
        if surface_id:
            s = next((s for s in self.surfaces() if s["id"] == surface_id), {})
            r["px"] = s.get("pixels")
        self.results[name] = r
        return r

    # MARK: Scenarios

    def launch(self, scenario):
        """Opens the Stress app on a fresh workspace: (pid, surface id, seconds to first frame)."""
        self.run("dispatch", "workspace", "empty")
        self.workspace = next(w["id"] for w in json.loads(self.run("workspaces")) if w.get("active"))
        before = {s["id"] for s in self.surfaces()}
        t0 = time.time()
        self.run("launch", "QML Stress", scenario, timeout=30)
        s = self.wait(f"{scenario} to draw", lambda: next(
            (s for s in self.surfaces() if s["id"] not in before and s.get("app") == "dev.gavrix.hyprmux.stress"
             and s.get("framesShown", 0) >= 1), None))
        return s["pid"], s["id"], time.time() - t0

    def close(self, pid):
        subprocess.run(["kill", str(pid)], capture_output=True)
        time.sleep(0.5)

    def scenario(self, name):
        if name == "startup":
            pid, sid, secs = self.launch("idle")
            total, graphics = self.footprint(pid)
            self.results["startup"] = {"first_frame_s": round(secs, 2), "memory_mb": round(total or 0, 1),
                                       "graphics_mb": round(graphics or 0, 1)}
            self.close(pid)
        elif name in ("idle", "full", "scene", "gpu", "list"):
            pid, sid, _ = self.launch(name)
            time.sleep(2)   # warm up: caches, glyphs, first delegates
            r = self.measure(name, pid, sid)
            if name != "idle" and (r["fps"] or 0) < 5:
                print("      (almost no frames: is the bench's Hyprmux window on screen, on this Space?"
                      " --front brings it there)", file=sys.stderr)
            self.close(pid)
        elif name in ("hidden", "hidden-scene"):
            # An animated scenario on a workspace out of view: no frame callbacks, so
            # no rendering. What's left is the animations ticking and their bindings.
            pid, sid, _ = self.launch("full" if name == "hidden" else "scene")
            time.sleep(1)
            self.run("move-surface", "--surface", f"surface:{sid}", "--workspace", "empty")
            time.sleep(1)
            self.measure(name, pid, sid)
            self.close(pid)
        elif name == "resize":
            # The list next to a terminal, resized back and forth ten times a second.
            pid, sid, _ = self.launch("list")
            self.run("new-surface", "--type", "terminal", "--workspace", self.workspace)
            time.sleep(1.5)
            self.run("focus-surface", "--surface", f"surface:{sid}")

            def wiggle(until):
                step = 1
                while time.time() < until:
                    self.run("dispatch", "--surface", f"surface:{sid}", "resizeactive", f"{120 * step} 0", check=False)
                    step = -step
                    time.sleep(0.1)
            self.measure("resize", pid, sid, during=wiggle)
            self.close(pid)
        elif name == "plugin":
            # sysload, idle in the bar: its budget.
            time.sleep(1)
            self.measure("plugin", self.plugin_pid, None, role="bar_item")


def ms(t, key="avg"):
    return f"{t[key]:.2f}" if t else "-"


def report(results):
    head = ["scenario", "px", "fps", "render avg/p95", "submit avg/p95", "finish avg", "callback avg", "configure p95",
            "starved", "app cpu%", "hyprmux cpu%", "memory MB", "buffers/metal MB"]
    rows = []
    for name, r in results.items():
        if name == "startup":
            continue
        rows.append([name, "x".join(map(str, r.get("px") or [])) or "-", str(r["fps"] if r["fps"] is not None else "-"),
                     f"{ms(r['render'])} / {ms(r['render'], 'p95')}", f"{ms(r['submit'])} / {ms(r['submit'], 'p95')}",
                     ms(r["gpu_wait"]),
                     ms(r["callback"]), ms(r["configure"], "p95"), str(r["starved"]), str(r["app_cpu"]),
                     str(r["hyprmux_cpu"]), str(r["memory_mb"]), f"{r['surfaces_mb']} / {r['metal_mb']}"])
    widths = [max(len(h), *(len(row[i]) for row in rows)) if rows else len(h) for i, h in enumerate(head)]
    print("  ".join(h.ljust(w) for h, w in zip(head, widths)))
    for row in rows:
        print("  ".join(c.ljust(w) for c, w in zip(row, widths)))
    if "startup" in results:
        s = results["startup"]
        print(f"\nstartup: first frame {s['first_frame_s']} s after launch; idle app {s['memory_mb']} MB "
              f"({s['graphics_mb']} MB graphics)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", default=os.environ.get("HYPRMUX_APP", "/tmp/HyprmuxTest.app"))
    ap.add_argument("--seconds", type=float, default=8)
    ap.add_argument("--json", help="also write the results here")
    ap.add_argument("--front", action="store_true",
                    help="bring the bench's Hyprmux to the front, so frames flow (it takes the keyboard)")
    ap.add_argument("scenarios", nargs="*", default=ALL)
    args = ap.parse_args()
    unknown = [s for s in args.scenarios if s not in ALL]
    if unknown:
        ap.error(f"unknown scenario {', '.join(unknown)}; known: {', '.join(ALL)}")
    app = Path(args.app)
    if not (app / "Contents/MacOS/hyprmux-qml").exists():
        sys.exit(f"{app} has no QML host: build one with HYPRMUX_APP={app} scripts/bundle.sh")

    bench = Bench(app, args.seconds, args.front)
    try:
        bench.start()
        for name in args.scenarios:
            print(f"... {name}", file=sys.stderr)
            try:
                bench.scenario(name)
            except Exception as e:   # one broken scenario shouldn't lose the others
                print(f"      {name} failed: {e}", file=sys.stderr)
    finally:
        bench.stop()
    report(bench.results)
    if args.json:
        Path(args.json).write_text(json.dumps(bench.results, indent=2))


if __name__ == "__main__":
    main()
