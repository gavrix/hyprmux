// Hyprmux's markdown viewer. The page (MarkdownViewer.swift) carries the file's text in
// #hm-source. Hyprmux calls hyprmux.update(text) when the file changes on disk.
(() => {
  "use strict";

  const md = window.markdownit({
    html: true,
    linkify: true,
    highlight(code, lang) {
      if (lang && hljs.getLanguage(lang)) {
        try {
          return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
        } catch (_) {}
      }
      return "";  // markdown-it escapes it
    },
  });

  // Source lines on blocks, so #L42 can scroll to the block that holds line 42.
  md.core.ruler.push("hm_lines", (state) => {
    for (const t of state.tokens) {
      if (t.map && t.nesting !== -1 && t.type !== "inline") {
        t.attrSet("data-line", String(t.map[0] + 1));
        t.attrSet("data-line-end", String(t.map[1]));
      }
    }
  });

  // GitHub-style heading ids, so #section links work.
  md.core.ruler.push("hm_anchors", (state) => {
    const used = new Map();
    const tokens = state.tokens;
    for (let i = 0; i < tokens.length - 1; i++) {
      if (tokens[i].type !== "heading_open") continue;
      const text = (tokens[i + 1].children || [])
        .filter((c) => c.type === "text" || c.type === "code_inline")
        .map((c) => c.content)
        .join("");
      let slug = text.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").replace(/\s/g, "-");
      const n = used.get(slug) || 0;
      used.set(slug, n + 1);
      if (n > 0) slug += "-" + n;
      tokens[i].attrSet("id", slug);
    }
  });

  // Task lists: "- [ ] item" and "- [x] item".
  md.core.ruler.push("hm_tasks", (state) => {
    const tokens = state.tokens;
    for (let i = 2; i < tokens.length; i++) {
      const t = tokens[i];
      if (t.type !== "inline" || tokens[i - 1].type !== "paragraph_open" || tokens[i - 2].type !== "list_item_open") continue;
      const first = t.children && t.children[0];
      if (!first || first.type !== "text") continue;
      const m = /^\[([ xX])\](?=\s|$)\s?/.exec(first.content);
      if (!m) continue;
      first.content = first.content.slice(m[0].length);
      const box = new state.Token("html_inline", "", 0);
      box.content = `<input type="checkbox" class="task-list-item-checkbox" disabled${m[1] === " " ? "" : " checked"}> `;
      t.children.unshift(box);
      const item = tokens[i - 2];
      item.attrJoin("class", "task-list-item");
      for (let j = i - 3; j >= 0; j--) {
        const list = tokens[j];
        if ((list.type === "bullet_list_open" || list.type === "ordered_list_open") && list.level === item.level - 1) {
          list.attrJoin("class", "contains-task-list");
          break;
        }
      }
    }
  });

  // GitHub alerts: a blockquote that starts with [!NOTE], [!TIP], [!IMPORTANT], [!WARNING], or [!CAUTION].
  const alertTitles = { note: "Note", tip: "Tip", important: "Important", warning: "Warning", caution: "Caution" };
  md.core.ruler.push("hm_alerts", (state) => {
    const tokens = state.tokens;
    for (let i = 0; i + 2 < tokens.length; i++) {
      const open = tokens[i];
      const inline = tokens[i + 2];
      if (open.type !== "blockquote_open" || tokens[i + 1].type !== "paragraph_open" || inline.type !== "inline") continue;
      const m = /^\[!(note|tip|important|warning|caution)\]\s*$/i.exec(inline.content.split("\n")[0]);
      if (!m) continue;
      const kind = m[1].toLowerCase();
      // Drop the marker and the line break after it.
      const kids = inline.children || [];
      let cut = 0;
      while (cut < kids.length && kids[cut].type !== "softbreak" && kids[cut].type !== "hardbreak") cut++;
      inline.children = kids.slice(cut + 1);
      inline.content = inline.content.split("\n").slice(1).join("\n");
      open.tag = "div";
      open.attrJoin("class", `markdown-alert markdown-alert-${kind}`);
      let depth = 0;
      for (let j = i; j < tokens.length; j++) {
        if (tokens[j].type === "blockquote_open") depth++;
        if (tokens[j].type === "blockquote_close" && --depth === 0) {
          tokens[j].tag = "div";
          break;
        }
      }
      const title = new state.Token("html_block", "", 0);
      title.content = `<p class="markdown-alert-title">${alertTitles[kind]}</p>\n`;
      tokens.splice(i + 1, 0, title);
      // An alert with only the marker has an empty paragraph left; that's fine.
    }
  });

  const doc = document.getElementById("hm-doc");

  function render(text) {
    const html = md.render(text);
    doc.innerHTML = DOMPurify.sanitize(html, { ADD_ATTR: ["data-line", "data-line-end"] });
  }

  // The deepest block that holds a source line. On a blank line between blocks, the one before.
  // Blocks come in document order, so a block's children come after it.
  function blockForLine(line) {
    let holder = null;
    let before = null;
    for (const el of doc.querySelectorAll("[data-line]")) {
      if (Number(el.dataset.line) > line) break;
      before = el;
      if (line <= Number(el.dataset.lineEnd)) holder = el;
    }
    return holder || before;
  }

  function scrollToHash(flash) {
    const hash = decodeURIComponent(location.hash.slice(1));
    if (!hash) return;
    const m = /^L(\d+)$/.exec(hash);
    const el = m ? blockForLine(Number(m[1])) : document.getElementById(hash);
    if (!el) return;
    el.scrollIntoView({ block: m ? "center" : "start" });
    if (m && flash) {
      el.classList.remove("hm-flash");
      void el.offsetWidth;  // restart the animation
      el.classList.add("hm-flash");
    }
  }

  // The first block at the top of the window and how far it has scrolled, so an
  // update can put the same text back in the same place.
  function topAnchor() {
    for (const el of doc.querySelectorAll("[data-line]")) {
      const r = el.getBoundingClientRect();
      if (r.bottom > 0) return { line: el.dataset.line, offset: r.top };
    }
    return null;
  }

  window.hyprmux = {
    update(text) {
      const anchor = topAnchor();
      const y = window.scrollY;
      render(text);
      const el = anchor && doc.querySelector(`[data-line="${anchor.line}"]`);
      if (el) window.scrollBy(0, el.getBoundingClientRect().top - anchor.offset);
      else window.scrollTo(0, y);
    },
  };

  window.addEventListener("hashchange", () => scrollToHash(true));

  render(JSON.parse(document.getElementById("hm-source").textContent));
  scrollToHash(true);
})();
