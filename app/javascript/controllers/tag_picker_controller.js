import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["input", "chip", "option", "dropdown", "search"];

  connect() {
    this.#buildIndex();
    this.#closeDropdown();
    this.refresh();
  }

  handleDropdownToggle() {
    if (this.dropdownTarget?.open && this.hasSearchTarget) {
      this.searchTarget.focus();
      this.searchTarget.select();
    }
  }

  // Called when a candidate tag is clicked in the dropdown.
  select(event) {
    event.preventDefault();
    this.#setChecked(event.currentTarget.dataset.tagId, true);
    if (!this.#hasSelectableOptions()) this.#closeDropdown();
  }

  // Called when a selected chip is clicked — removes it from the selected area.
  deselect(event) {
    event.preventDefault();
    this.#setChecked(event.currentTarget.dataset.tagId, false);
  }

  // Filters candidate options by the search input value.
  filterOptions() {
    if (!this.hasSearchTarget) return;

    const query = this.searchTarget.value.trim().toLowerCase();
    this.optionTargets.forEach((option) => {
      const match = option.dataset.tagName.includes(query);
      option.style.display = match ? "" : "none";
    });
  }

  // Syncs chip visibility and option disabled state with checkbox state.
  refresh() {
    this.inputTargets.forEach((input) => {
      const tagId = input.dataset.tagId;
      const selected = input.checked;

      const chip = this.chipByTagId.get(tagId);
      if (chip) {
        // Toggle both classes to avoid Tailwind cascade conflicts
        chip.classList.toggle("inline-flex", selected);
        chip.classList.toggle("hidden", !selected);
      }

      const option = this.optionByTagId.get(tagId);
      if (option) option.disabled = selected || input.disabled;
    });

    this.filterOptions();
  }

  #setChecked(tagId, checked) {
    const input = this.inputByTagId.get(tagId);
    if (!input || input.disabled) return;
    input.checked = checked;
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }

  #buildIndex() {
    this.inputByTagId = new Map(this.inputTargets.map((el) => [el.dataset.tagId, el]));
    this.chipByTagId = new Map(this.chipTargets.map((el) => [el.dataset.tagId, el]));
    this.optionByTagId = new Map(this.optionTargets.map((el) => [el.dataset.tagId, el]));
  }

  #closeDropdown() {
    this.dropdownTarget?.removeAttribute("open");
  }

  #hasSelectableOptions() {
    return this.optionTargets.some((o) => !o.disabled);
  }
}
