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
