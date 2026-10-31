import { Controller } from "@hotwired/stimulus";

// Sort mode of the account sidebar, used with the manual account order.
// The drag handles stay hidden until the user turns sort mode on, so the
// list looks the same as with the other orders the rest of the time.
// Visibility is set inline (not with Tailwind classes) because the Docker
// image ships a precompiled CSS bundle, like the expand-all toggle.
export default class extends Controller {
  static targets = ["toggle", "bar", "handle"];

  // Also resets markup restored from Turbo's page cache in sort mode.
  connect() {
    this.sorting = false;
    this.render();
  }

  toggle() {
    this.sorting ? this.stop() : this.start();
  }

  start() {
    this.sorting = true;
    this.render();
    // Handles inside collapsed groups would stay out of sight. They close
    // again when sort mode ends.
    this.openedGroups = new Set();
    this.handleTargets.forEach((handle) => {
      const group = handle.closest("details");
      if (group && !group.open) {
        group.open = true;
        this.openedGroups.add(group);
      }
    });
  }

  stop() {
    const active = document.activeElement;
    const focusWillHide =
      this.handleTargets.includes(active) ||
      this.barTargets.some((bar) => bar.contains(active));

    // A row picked up with the keyboard is dropped and saved where it is.
    window.dispatchEvent(new CustomEvent("account-sort-mode:stop"));

    this.sorting = false;
    this.render();
    this.openedGroups?.forEach((group) => {
      group.open = false;
    });
    this.openedGroups = null;
    if (focusWillHide) this.focusAfterStop();
  }

  // Handles rendered later (e.g. another tab's list) follow the current mode.
  handleTargetConnected(handle) {
    this.renderHandle(handle);
  }

  // Also runs after a Turbo morph refresh, which restores the server markup.
  render() {
    const display = this.sorting ? "" : "none";
    this.handleTargets.forEach((handle) => this.renderHandle(handle));
    this.barTargets.forEach((bar) => {
      bar.style.display = display;
    });
    this.toggleTargets.forEach((toggle) => {
      toggle.setAttribute("aria-pressed", this.sorting ? "true" : "false");
    });
  }

  // Rows can only be dragged in sort mode, so outside it a press on an
  // account link or a text selection behaves as usual. In sort mode the link
  // inside a row is not draggable on its own, so dragging it moves the row.
  renderHandle(handle) {
    handle.style.display = this.sorting ? "" : "none";
    const item = handle.closest("[data-sortable-list-target='item']");
    if (!item) return;

    item.draggable = this.sorting;
    item.querySelectorAll("a").forEach((link) => {
      if (this.sorting) {
        link.setAttribute("draggable", "false");
      } else {
        link.removeAttribute("draggable");
      }
    });
  }

  // Keeps keyboard users in the sidebar when the focused handle or bar hides:
  // on the visible sort toggle, or on the sidebar itself when the active tab
  // has none, instead of letting focus fall back to the page body.
  focusAfterStop() {
    const toggle = this.toggleTargets.find(
      (toggle) => toggle.offsetParent !== null,
    );
    if (toggle) {
      toggle.focus();
      return;
    }

    if (!this.element.hasAttribute("tabindex")) {
      this.element.setAttribute("tabindex", "-1");
    }
    this.element.focus();
  }
}
