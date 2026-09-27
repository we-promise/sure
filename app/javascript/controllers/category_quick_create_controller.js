import { Controller } from "@hotwired/stimulus";

// Lets the transaction list's quick category picker create a category that
// doesn't exist yet. The new category is assigned by submitting the same
// update form a normal row uses, so the row refreshes in place and the
// "create a rule?" prompt still appears.
export default class extends Controller {
  static targets = [
    "input",
    "createButton",
    "createLabel",
    "assignForm",
    "categoryIdField",
    "error",
  ];

  static values = {
    createUrl: String,
    color: String,
    labelTemplate: String,
    errorMessage: String,
    existingNames: Array,
  };

  connect() {
    this.update();
  }

  update() {
    const name = this.inputTarget.value.trim();
    const canCreate = name.length > 0 && !this.nameExists(name);

    this.createButtonTarget.classList.toggle("hidden", !canCreate);
    this.createButtonTarget.classList.toggle("flex", canCreate);

    if (canCreate) {
      this.createLabelTarget.textContent = this.labelTemplateValue.replace(
        "__NAME__",
        name,
      );
    }

    this.clearError();
  }

  // Enter creates only when the search matches no row at all; otherwise
  // list-filter keeps handling Enter to pick the highlighted row.
  createOnEnter(event) {
    if (this.createButtonTarget.classList.contains("hidden")) return;
    if (this.hasVisibleRows) return;

    event.preventDefault();
    this.create();
  }

  async create() {
    if (this.creating) return;

    const name = this.inputTarget.value.trim();
    if (!name) return;

    this.creating = true;
    this.createButtonTarget.disabled = true;
    this.clearError();

    try {
      const response = await fetch(this.createUrlValue, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken,
        },
        body: JSON.stringify({ category: { name, color: this.colorValue } }),
      });
      const body = await response.json().catch(() => ({}));

      if (!response.ok || !body.id) {
        this.showError(body.errors?.join(", ") || body.error);
        return;
      }

      this.categoryIdFieldTarget.value = body.id;
      this.assignFormTarget.requestSubmit();
    } catch {
      this.showError();
    } finally {
      this.creating = false;
      this.createButtonTarget.disabled = false;
    }
  }

  nameExists(name) {
    const wanted = name.toLocaleLowerCase();
    return this.existingNamesValue.some(
      (existing) => existing.toLocaleLowerCase() === wanted,
    );
  }

  get hasVisibleRows() {
    return Array.from(this.element.querySelectorAll(".filterable-item")).some(
      (item) => item.style.display !== "none" && item.offsetParent !== null,
    );
  }

  showError(message) {
    this.errorTarget.textContent = message || this.errorMessageValue;
    this.errorTarget.classList.remove("hidden");
  }

  clearError() {
    this.errorTarget.textContent = "";
    this.errorTarget.classList.add("hidden");
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content;
  }
}
