import { Controller } from "@hotwired/stimulus";

// Free-text + status-chip filter for the savings-goals index grid.
// Mirrors the providers-filter pattern. Each card has data-goal-name
// and data-goal-status; the controller toggles `.hidden` on cards
// based on the active query/chip.
export default class extends Controller {
  static targets = ["input", "chip", "card", "empty", "grid", "count"];
  static values = { status: { type: String, default: "all" } };

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
