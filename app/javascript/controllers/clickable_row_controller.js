import { Controller } from "@hotwired/stimulus";

// Delegates a click anywhere on a list row (avatar, whitespace, cells with
// no control of their own) to the row's primary link, so the whole row
// looks and behaves as clickable rather than only the exact link text.
// Clicks on real interactive descendants (checkbox, category menu, account
// link, kebab menu, etc.) are left alone so they keep handling themselves.
export default class extends Controller {
  static targets = ["link"];

  open(event) {
    if (event.target.closest("a, button, input, select, textarea, label")) return;
    if (window.getSelection().toString().length > 0) return;

    this.linkTarget.click();
  }
}
