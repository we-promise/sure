import { Controller } from "@hotwired/stimulus";

// Shows the release-date fields only while the account is locked: either
// chosen by hand, or "automatic" on a subtype whose default is locked. Follows
// the subtype select in the same form, so switching a savings account to a
// term deposit before saving shows the date it now needs.
export default class extends Controller {
  static targets = ["level", "lockedFields"];
  static values = {
    defaultLevel: String,
    defaults: Object,
    labels: Object,
    automaticTemplate: String,
  };

  connect() {
    this.subtypeSelect = this.element
      .closest("form")
      ?.querySelector("select[name$='[subtype]']");
    this.onSubtypeChange = () => this.subtypeChanged();
    this.subtypeSelect?.addEventListener("change", this.onSubtypeChange);
    this.refresh();
  }

  disconnect() {
    this.subtypeSelect?.removeEventListener("change", this.onSubtypeChange);
  }

  subtypeChanged() {
    const level = this.defaultsValue[this.subtypeSelect.value];
    if (!level) return;

    this.defaultLevelValue = level;
    const automatic = this.levelTarget.querySelector(
      "option[value='automatic']",
    );
    if (automatic) {
      automatic.textContent = this.automaticTemplateValue.replace(
        "__LEVEL__",
        this.labelsValue[level] || level,
      );
    }
    this.refresh();
  }

  refresh() {
    const level = this.levelTarget.value;
    const locked =
      level === "locked" ||
      (level === "automatic" && this.defaultLevelValue === "locked");

    this.lockedFieldsTargets.forEach((field) => {
      field.classList.toggle("hidden", !locked);
    });
  }
}
