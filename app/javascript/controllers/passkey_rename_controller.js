import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["display", "edit", "input", "labelText"];
  static values = {
    url: String
  };

  startEdit() {
    this.displayTarget.classList.add("hidden");
    this.editTarget.classList.remove("hidden");
    this.inputTarget.focus();
    this.inputTarget.select();
  }

  cancel() {
    this.editTarget.classList.add("hidden");
    this.displayTarget.classList.remove("hidden");
    this.inputTarget.value = this.labelTextTarget.textContent;
  }

  async save() {
    const newLabel = this.inputTarget.value.trim();

    if (!newLabel) {
      this.cancel();
      return;
    }

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": this.csrfToken
        },
        body: JSON.stringify({ label: newLabel })
      });

      const result = await response.json();

      if (result.success) {
        this.labelTextTarget.textContent = result.passkey.label;
        this.editTarget.classList.add("hidden");
        this.displayTarget.classList.remove("hidden");
      } else {
        console.error("Failed to rename passkey:", result.error);
      }
    } catch (error) {
      console.error("Failed to rename passkey:", error);
    }
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content;
  }
}
