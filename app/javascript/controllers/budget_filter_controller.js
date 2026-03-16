import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["onTrack", "overBudget", "tab"];
  static values = { filter: { type: String, default: "all" } };

  setFilter(event) {
    this.filterValue = event.params.filter;
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
}
