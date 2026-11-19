import { Controller } from "@hotwired/stimulus";

// Sort mode of the account sidebar, used with the manual account order.
// The drag handles stay hidden until the user turns sort mode on, so the
// list looks the same as with the other orders the rest of the time.
// Visibility is set inline (not with Tailwind classes) because the Docker
// image ships a precompiled CSS bundle, like the expand-all toggle.
export default class extends Controller {
  static targets = ["toggle", "bar", "handle", "orderOption", "reorderItem"];
  static values = { order: String, url: String };

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

  // Picked in the sidebar settings menu. Re-sorts the rows in place (no
  // reload, so open groups stay open), saves the order in the background,
  // and opens sort mode right away when switching to the custom order.
  setOrder(event) {
    const order = event.params.order;
    if (!order) return;

    const switchingToManual = order === "manual" && this.orderValue !== "manual";
    if (this.sorting && order !== "manual") this.stop();
    this.applyOrder(order);
    window.dispatchEvent(
      new CustomEvent("account-sort-mode:order", { detail: { order, source: this } }),
    );
    this.saveOrder(order);
    if (switchingToManual) this.start();
  }

  // Keeps the other sidebar instance (desktop vs mobile) in step.
  syncOrder(event) {
    if (event.detail?.source === this) return;
    const order = event.detail.order;
    if (this.sorting && order !== "manual") this.stop();
    this.applyOrder(order);
  }

  // "Expand all" / "Collapse all" in the settings menu. Only the groups in the
  // menu's own tab panel change; the menu panel stays inside it in the DOM.
  setGroupsOpen(event) {
    const open = event.params.open === true || event.params.open === "true";
    const panel = event.currentTarget.closest("[role=tabpanel]") || this.element;
    panel.querySelectorAll("details").forEach((group) => {
      group.open = open;
    });
  }

  applyOrder(order) {
    this.orderValue = order;
    this.element
      .querySelectorAll("[data-controller~='sortable-list']")
      .forEach((list) => this.sortList(list, order));
  }

  orderValueChanged() {
    const order = this.orderValue;
    this.orderOptionTargets.forEach((option) => {
      const selected = option.dataset.order === order;
      option.setAttribute("aria-pressed", selected ? "true" : "false");
      const check = option.querySelector("[data-menu-item-check]");
      if (check) check.style.display = selected ? "" : "none";
    });
    this.reorderItemTargets.forEach((item) => {
      item.style.display = order === "manual" ? "" : "none";
    });
  }

  // Same rules as BalanceSheet#sorted on the server: lowercased name, then
  // balance converted to the family currency, each with the account id as the
  // tie-break (the descending orders reverse the whole key), and for the
  // custom order the saved positions first, then the rest by name.
  sortList(list, order) {
    const items = Array.from(list.children).filter(
      (el) => el.dataset.sortableListTarget === "item",
    );
    if (items.length < 2) return;

    const compareStrings = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
    const name = (el) => el.dataset.sortName || "";
    const id = (el) => el.dataset.sortableListId || "";
    const balance = (el) => Number.parseFloat(el.dataset.sortBalance || "0");
    const byName = (a, b) =>
      compareStrings(name(a), name(b)) || compareStrings(id(a), id(b));
    const byBalance = (a, b) => balance(a) - balance(b) || compareStrings(id(a), id(b));
    const position = (el) =>
      el.dataset.manualPosition === undefined || el.dataset.manualPosition === ""
        ? null
        : Number.parseInt(el.dataset.manualPosition, 10);

    const comparators = {
      name_asc: byName,
      name_desc: (a, b) => byName(b, a),
      balance_asc: byBalance,
      balance_desc: (a, b) => byBalance(b, a),
      manual: (a, b) => {
        const pa = position(a);
        const pb = position(b);
        if (pa !== null && pb !== null) return pa - pb;
        if (pa !== null) return -1;
        if (pb !== null) return 1;
        return byName(a, b);
      },
    };
    const compare = comparators[order];
    if (!compare) return;

    items.sort(compare).forEach((item) => list.appendChild(item));
  }

  // One write at a time: an order picked while a save is running is sent once
  // it finishes, so a slow earlier request can't overwrite a later choice.
  saveOrder(order) {
    if (!this.urlValue) return;
    this.pendingOrder = order;
    if (!this.saving) this.flushOrder();
  }

  async flushOrder() {
    this.saving = true;
    while (this.pendingOrder) {
      const order = this.pendingOrder;
      this.pendingOrder = null;
      const saved = await this.sendOrder(order);
      if (!saved) {
        this.pendingOrder = null;
        // Show the order that is actually saved.
        window.Turbo?.visit(window.location.href, { action: "replace" });
      }
    }
    this.saving = false;
  }

  async sendOrder(order) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    const headers = { "Content-Type": "application/json", Accept: "application/json" };
    if (csrfToken) headers["X-CSRF-Token"] = csrfToken;

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers,
        body: JSON.stringify({ order }),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return true;
    } catch (error) {
      console.error("[Account sort mode] Failed to save order:", error);
      return false;
    }
  }

  // After dragging, the rows' DOM order is the custom order; record it so a
  // later switch back to the custom order (without a reload) restores it.
  // Positions are read from this sidebar and written to every copy of a row
  // (other tabs, the other sidebar instance), which the drag mirrored.
  recordManualPositions() {
    const positions = new Map();
    this.element
      .querySelectorAll("[data-controller~='sortable-list']")
      .forEach((list) => {
        Array.from(list.children)
          .filter((el) => el.dataset.sortableListTarget === "item")
          .forEach((item, index) => positions.set(item.dataset.sortableListId, index));
      });

    positions.forEach((position, id) => {
      if (!id) return;
      document
        .querySelectorAll(`[data-sortable-list-target='item'][data-sortable-list-id='${CSS.escape(id)}']`)
        .forEach((item) => {
          item.dataset.manualPosition = String(position);
        });
    });
  }

  stop() {
    if (this.sorting && this.orderValue === "manual") this.recordManualPositions();

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
  // and the logo inside a row are not draggable on their own, so dragging
  // them moves the row.
  renderHandle(handle) {
    handle.style.display = this.sorting ? "" : "none";
    const item = handle.closest("[data-sortable-list-target='item']");
    if (!item) return;

    item.draggable = this.sorting;
    item.querySelectorAll("a, img").forEach((element) => {
      if (this.sorting) {
        element.setAttribute("draggable", "false");
      } else {
        element.removeAttribute("draggable");
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
