import { Controller } from "@hotwired/stimulus";

// Syncs a textarea with its prompt override's hidden input. Pre-fills with the
// custom override or built-in default. Clears the input when text matches
// the default to avoid storing duplicate copies.
export default class extends Controller {
  static outlets = ["confirm-dialog"];
  static targets = ["textarea", "prompt", "status", "counter", "reset"];
  static values = {
    resetConfirm: String,
    statusCustom: String,
    statusDefault: String,
    maxLength: Number,
  };

  connect() {
    this.updateStatus();
  }

  update() {
    const prompt = this.promptTarget;
    const value = this.textareaTarget.value;
    prompt.value = value.trim() === prompt.dataset.default.trim() ? "" : value;
    this.updateStatus();
  }

  async reset() {
    const confirmDialog = this.hasConfirmDialogOutlet
      ? this.confirmDialogOutlet
      : null;
    const confirmed = confirmDialog
      ? await confirmDialog.handleConfirm(this.resetConfirmValue)
      : window.confirm(this.resetConfirmValue);

    if (!confirmed) return;

    const prompt = this.promptTarget;
    prompt.value = "";
    this.textareaTarget.value = prompt.dataset.default;
    this.updateStatus();
  }

  updateStatus() {
    const prompt = this.promptTarget;
    const customized = (prompt.value || "").trim().length > 0;

    if (this.hasStatusTarget) {
      this.statusTarget.textContent = customized
        ? this.statusCustomValue
        : this.statusDefaultValue;
    }

    if (this.hasCounterTarget && this.hasMaxLengthValue) {
      const length = Array.from(this.textareaTarget.value).length;
      const over = length > this.maxLengthValue;
      this.counterTarget.textContent = `${length.toLocaleString()} / ${this.maxLengthValue.toLocaleString()}`;
      this.counterTarget.classList.toggle("text-destructive", over);
      this.counterTarget.classList.toggle("text-secondary", !over);
    }

    if (this.hasResetTarget) {
      this.resetTarget.disabled = !customized;
    }
  }
}
