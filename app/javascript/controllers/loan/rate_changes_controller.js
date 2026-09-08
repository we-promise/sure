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

  // Seeded from Date.now() so a new row's index never collides with the small
  // sequential indices Rails renders for existing rows, then incremented so two
  // rows added within the same millisecond stay distinct (a bare Date.now()
  // would give both the same index and Rails would merge them into one record).
  #uniqueKey() {
    this.nextIndex ??= Date.now();
    return this.nextIndex++;
  }
}
