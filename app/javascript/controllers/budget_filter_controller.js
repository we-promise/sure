import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["onTrack", "overBudget", "tab"];
  static values = { filter: { type: String, default: "all" } };

  connect() {
    const filterParam = new URLSearchParams(window.location.search).get("filter");

    if (this.#isValidFilter(filterParam)) {
      this.filterValue = filterParam;
      return;
    }

    this.filterValueChanged();
  }

  setFilter(event) {
    this.filterValue = event.params.filter;
    this.#syncFilterParam();
  }

  filterValueChanged() {
    const filter = this.filterValue;

    if (this.hasOnTrackTarget) {
      this.onTrackTarget.hidden = filter === "over_budget";
    }

    if (this.hasOverBudgetTarget) {
      this.overBudgetTarget.hidden = filter === "on_track";
    }

    this.tabTargets.forEach((tab) => {
      const isActive = tab.dataset.budgetFilterFilterParam === filter;
      tab.classList.toggle("bg-container", isActive);
      tab.classList.toggle("text-primary", isActive);
      tab.classList.toggle("shadow-sm", isActive);
      tab.classList.toggle("text-secondary", !isActive);
    });
  }

  #isValidFilter(filter) {
    return ["all", "over_budget", "on_track"].includes(filter);
  }

  #syncFilterParam() {
    const url = new URL(window.location.href);

    if (this.filterValue === "all") {
      url.searchParams.delete("filter");
    } else {
      url.searchParams.set("filter", this.filterValue);
    }

    window.history.replaceState({}, "", url);
  }
}
