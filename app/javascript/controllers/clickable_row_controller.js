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
    // Popover/menu panels (category dropdown, account/kebab menus, etc.)
    // render as `position: fixed` but stay DOM descendants of the row, so a
    // click anywhere on their background (padding, headings, plain text)
    // would otherwise fall through to the row's own link.
    if (event.target.closest('[data-ds--popover-target="content"], [data-ds--menu-target="content"]')) return;
    if (window.getSelection().toString().length > 0) return;

    // Re-dispatch as a click on the link itself (rather than calling
    // `.click()`) so modifier keys (Cmd/Ctrl/Shift) are preserved and the
    // browser/Turbo can open the link in a new tab/window as expected.
    const clickEvent = new MouseEvent("click", {
      bubbles: true,
      cancelable: true,
      view: window,
      ctrlKey: event.ctrlKey,
      metaKey: event.metaKey,
      shiftKey: event.shiftKey,
      altKey: event.altKey,
    });
    this.linkTarget.dispatchEvent(clickEvent);
  }
}
