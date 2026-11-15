import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="auto-match-bulk-select"
// Lightweight row-selection for the auto matches review table: toggles a
// selection bar with confirm/reject buttons that submit the selected
// transfer ids to AutoMatchesController#bulk_update.
export default class extends Controller {
  static targets = ["selectAll", "row", "bar", "count"];

  connect() {
    this._updateBar();
  }

  toggleAll(e) {
    this.rowTargets.forEach((row) => {
      row.checked = e.target.checked;
    });
    this._updateBar();
  }

  toggleRow() {
    if (this.hasSelectAllTarget) {
      this.selectAllTarget.checked =
        this.rowTargets.length > 0 && this.rowTargets.every((row) => row.checked);
    }
    this._updateBar();
  }

  populateIds(e) {
    const form = e.target;
    form.querySelectorAll("input[name='transfer_ids[]']").forEach((el) => el.remove());

    this._selectedIds().forEach((id) => {
      const input = document.createElement("input");
      input.type = "hidden";
      input.name = "transfer_ids[]";
      input.value = id;
      form.appendChild(input);
    });
  }

  _selectedIds() {
    return this.rowTargets.filter((row) => row.checked).map((row) => row.dataset.id);
  }

  _updateBar() {
    const selected = this._selectedIds().length;
    if (this.hasBarTarget) {
      this.barTarget.classList.toggle("hidden", selected === 0);
    }
    if (this.hasCountTarget) {
      this.countTarget.textContent = selected;
    }
  }
}
