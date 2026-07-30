import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="loan--rate-changes"
//
// Manages the loan rate-changes nested form: appends new rows from a <template>
// and removes rows, marking persisted ones for destruction so `accepts_nested_
// attributes_for :rate_changes, allow_destroy: true` deletes them on save.
export default class extends Controller {
  static targets = ["list", "template"];

  add(e) {
    e.preventDefault();

    const html = this.templateTarget.innerHTML.replaceAll(
      "IDX_PLACEHOLDER",
      this.#uniqueKey(),
    );

    this.listTarget.insertAdjacentHTML("beforeend", html);
  }

  remove(e) {
    e.preventDefault();

    const row = e.target.closest("[data-rate-change-row]");
    if (!row) return;

    if (row.dataset.persisted === "true") {
      const destroyField = row.querySelector("input[name*='_destroy']");
      if (destroyField) destroyField.value = "1";
      row.classList.add("hidden");
    } else {
      row.remove();
    }
  }

  #uniqueKey() {
    return Date.now();
  }
}
