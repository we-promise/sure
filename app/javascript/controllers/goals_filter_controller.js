import { Controller } from "@hotwired/stimulus";

// Free-text + status-chip filter for the goals index grid.
// Mirrors the providers-filter pattern. Each card has data-goal-name
// and data-goal-status; the controller toggles `.hidden` on cards
// based on the active query/chip.
export default class extends Controller {
  static targets = [
    "input",
    "chip",
    "card",
    "empty",
    "emptyCopy",
    "emptyClearSearch",
    "emptyClearFilter",
    "grid",
    "count",
  ];
  static values = {
    status: { type: String, default: "all" },
    emptyQuery: { type: String, default: "" },
    emptyFilter: { type: String, default: "" },
    emptyBoth: { type: String, default: "" },
    emptyDefault: { type: String, default: "" },
  };

  connect() {
    this.#hydrateFromUrl();
    this.syncChipState();
    if (this.statusValue !== "all" || (this.hasInputTarget && this.inputTarget.value)) {
      this.filter();
    }
  }

  disconnect() {
    clearTimeout(this._urlSyncTimer);
  }

  filter() {
    const query = this.hasInputTarget
      ? this.inputTarget.value.toLocaleLowerCase().trim()
      : "";
    const active = this.statusValue;
    let visible = 0;

    this.cardTargets.forEach((card) => {
      const name = (card.dataset.goalName || "").toLocaleLowerCase();
      const status = card.dataset.goalStatus || "";
      const matchesQuery = !query || name.includes(query);
      const matchesStatus = active === "all" || status === active;
      const show = matchesQuery && matchesStatus;
      card.classList.toggle("hidden", !show);
      if (show) visible++;
    });

    if (this.hasEmptyTarget) {
      this.emptyTarget.classList.toggle("hidden", visible > 0);
    }
    if (this.hasGridTarget) {
      this.gridTarget.classList.toggle("hidden", visible === 0);
    }
    if (this.hasCountTarget) {
      this.countTarget.textContent = visible;
    }

    this.updateEmptyState(visible, query, active);
    this.#scheduleUrlSync();
  }

  // Debounced wrapper. Firing replaceState on every keystroke is wasteful
  // and produced visible jank on slow CPUs; deferring 200 ms collapses a
  // typing burst into a single URL update without losing back-button
  // fidelity (replaceState doesn't create history entries anyway).
  #scheduleUrlSync() {
    clearTimeout(this._urlSyncTimer);
    this._urlSyncTimer = setTimeout(() => this.#syncUrl(), 200);
  }

  #hydrateFromUrl() {
    const params = new URLSearchParams(window.location.search);
    const status = params.get("filter");
    if (status && this.chipTargets.some((c) => c.dataset.status === status)) {
      this.statusValue = status;
    }
    const q = params.get("q");
    if (q && this.hasInputTarget) {
      this.inputTarget.value = q;
    }
  }

  #syncUrl() {
    const params = new URLSearchParams(window.location.search);
    if (this.statusValue && this.statusValue !== "all") {
      params.set("filter", this.statusValue);
    } else {
      params.delete("filter");
    }
    const q = this.hasInputTarget ? this.inputTarget.value.trim() : "";
    if (q) {
      params.set("q", q);
    } else {
      params.delete("q");
    }
    const qs = params.toString();
    const url = qs ? `${window.location.pathname}?${qs}` : window.location.pathname;
    window.history.replaceState(window.history.state, "", url);
  }

  updateEmptyState(visible, query, active) {
    if (visible > 0 || !this.hasEmptyCopyTarget) return;
    const rawQuery = this.hasInputTarget ? this.inputTarget.value.trim() : "";
    const hasQuery = rawQuery.length > 0;
    const hasFilter = active !== "all";
    let copy;
    if (hasQuery && hasFilter) {
      copy = this.emptyBothValue.replace("__QUERY__", rawQuery);
    } else if (hasQuery) {
      copy = this.emptyQueryValue.replace("__QUERY__", rawQuery);
    } else if (hasFilter) {
      copy = this.emptyFilterValue;
    } else {
      copy = this.emptyDefaultValue;
    }
    this.emptyCopyTarget.textContent = copy;
    if (this.hasEmptyClearSearchTarget) {
      this.emptyClearSearchTarget.classList.toggle("hidden", !hasQuery);
    }
    if (this.hasEmptyClearFilterTarget) {
      this.emptyClearFilterTarget.classList.toggle("hidden", !hasFilter);
    }
  }

  clearSearch() {
    if (this.hasInputTarget) {
      this.inputTarget.value = "";
      this.inputTarget.focus();
    }
    this.filter();
  }

  clearFilter() {
    this.statusValue = "all";
    this.syncChipState();
    this.filter();
  }

  selectChip(event) {
    this.statusValue = event.currentTarget.dataset.status || "all";
    this.syncChipState();
    this.filter();
  }

  syncChipState() {
    if (!this.hasChipTarget) return;
    this.chipTargets.forEach((chip) => {
      const active = chip.dataset.status === this.statusValue;
      chip.setAttribute("aria-pressed", active);
      chip.classList.toggle("segmented-control__segment--active", active);
    });
  }
}
