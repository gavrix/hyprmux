// A pretend pointer for the page's scripted demos.

const CURSOR_SVG = `<svg viewBox="0 0 20 24" width="20" height="24" aria-hidden="true"><path d="M2 1.5v18.2l4.6-4.3 3 6.9 3.2-1.4-3-6.8h6.4z" fill="#fff" stroke="#0b0c11" stroke-width="1.4" stroke-linejoin="round"/></svg>`;

/** The pretend pointer, with a ⌘ badge while the "key" is down. */
export class Cursor {
  constructor(area, { mod = "⌘" } = {}) {
    this.el = document.createElement("div");
    this.el.className = "hm-cursor";
    this.el.innerHTML = `${CURSOR_SVG}${mod ? `<span class="hm-cursor__mod">${mod}</span>` : ""}`;
    area.append(this.el);
    this.p = { x: 0, y: 0 };
  }
  set(p) {
    this.p = p;
    this.el.style.transform = `translate(${p.x}px, ${p.y}px)`;
  }
  show(on) { this.el.classList.toggle("is-shown", on); }
  hold(on) { this.el.classList.toggle("is-holding", on); }
  remove() { this.el.remove(); }
}
