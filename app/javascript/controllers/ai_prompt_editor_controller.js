import { Controller } from "@hotwired/stimulus";

// Syncs a single textarea with provider hidden inputs. Pre-fills with the
// custom override or built-in default. Clears the input when text matches
// the default to avoid storing duplicate copies.
export default class extends Controller {
  static targets = ["textarea", "prompt", "provider", "status", "reset"];
  static values = {
    resetConfirm: String,
    statusCustom: String,
    statusDefault: String,
  };

  connect() {
    this.updateStatus();
  }

  change() {
    const prompt = this.selectedPrompt();
    this.textareaTarget.value = prompt.value || prompt.dataset.default;
    this.updateStatus();
  }

  update() {
    const prompt = this.selectedPrompt();
    const value = this.textareaTarget.value;
    prompt.value = value.trim() === prompt.dataset.default.trim() ? "" : value;
    this.updateStatus();
  }

  async reset() {
    const dialogEl = document.getElementById("confirm-dialog");
    const confirmDialog =
      dialogEl &&
      this.application.getControllerForElementAndIdentifier(
        dialogEl,
        "confirm-dialog",
      );
    const confirmed = confirmDialog
      ? await confirmDialog.handleConfirm(this.resetConfirmValue)
      : window.confirm(this.resetConfirmValue);

    if (!confirmed) return;

    const prompt = this.selectedPrompt();
    prompt.value = "";
    this.textareaTarget.value = prompt.dataset.default;
    this.updateStatus();
  }

  selectedPrompt() {
    if (this.hasProviderTarget && this.providerTarget.value) {
      const found = this.promptTargets.find(
        (prompt) => prompt.dataset.key === this.providerTarget.value,
      );
      if (found) return found;
    }
    return this.promptTargets[0];
  }

  updateStatus() {
    const prompt = this.selectedPrompt();
    if (!prompt || !this.hasStatusTarget) return;

    const customized = (prompt.value || "").trim().length > 0;
    this.statusTarget.textContent = customized
      ? this.statusCustomValue
      : this.statusDefaultValue;
    if (this.hasResetTarget) {
      this.resetTarget.disabled = !customized;
    }
  }
}
