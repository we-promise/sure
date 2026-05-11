import { Controller } from "@hotwired/stimulus";

// Free-text + status-chip filter for the savings-goals index grid.
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
    this.syncChipState();
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
      chip.classList.toggle("bg-container", active);
      chip.classList.toggle("shadow-border-xs", active);
      chip.classList.toggle("text-primary", active);
      chip.classList.toggle("text-secondary", !active);
    });
  }
}
