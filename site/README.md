# hyprmux.app

The landing page. Plain HTML, CSS, and ES modules: no build step, so this folder
is the deployable site.

- **Preview:** `python3 -m http.server -d site 8080`, then open http://localhost:8080.
- **Share image:** `scripts/site/og.sh` renders `scripts/site/og.html` to `media/og.png`.
- **Hosting:** `_headers` and `_redirects` are for Cloudflare Pages. Other hosts
  ignore them. `404.html` uses root paths, so it expects the site at a domain root.
- **Fonts:** Inter and JetBrains Mono, latin subsets, under the SIL Open Font
  License (`fonts/*-OFL.txt`).
- **Motion:** the curves and durations in `css/site.css` come from the default
  `config/hyprmux.conf` (Hyprland speed × 100 ms).
- **Scripts:** `js/main.js` loads the rest on demand: `js/compositor/` (the hero's
  live tiling window, a small port of HyprmuxCore's dwindle layout and window
  manager), `js/playground.js` with `js/hyprlang.js` (the config playground), and
  `js/agents.js` (the hyprmuxctl demo). Without JavaScript every section still shows
  a static version.
- **Clips:** `media/clips/` holds the tile cards' clips and posters. They're
  recorded with `scripts/demo/record.sh --clip site-NAME` (local clip scripts),
  then trimmed and re-encoded; see `plans/landing-page.md` for sizes and trim points.

