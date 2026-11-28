import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="row-expander", on the button that reveals a
// table row belonging to another row: the per-account positions under a
// consolidated holding on the portfolio page. A <details> element cannot live
// inside a <table>, so the button names its detail row through aria-controls,
// toggles that row's `hidden` attribute and mirrors the state in
// aria-expanded. Nothing is persisted.
export default class extends Controller {
  toggle() {
    const row = document.getElementById(
      this.element.getAttribute("aria-controls"),
    );
    if (!row) return;

    const willExpand = row.hidden;
    row.hidden = !willExpand;
    this.element.setAttribute("aria-expanded", String(willExpand));
    this.element.classList.toggle("rotate-90", willExpand);
  }
}
