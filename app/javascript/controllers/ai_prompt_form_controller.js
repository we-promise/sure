import { Controller } from "@hotwired/stimulus";

// Confirms before saving custom prompt overrides that replace built-in
// instructions. Remembers the "Don't show this warning again" choice in
// localStorage.
export default class extends Controller {
  static targets = ["form", "dialog", "dontShowAgain"];
  static values = {
    storageKey: {
      type: String,
      default: "ai_prompts_dismiss_safety_warning",
    },
    maxLength: {
      type: Number,
      default: 20000,
    },
  };

  connect() {
    this.confirmed = false;
  }

  save(event) {
    if (this.confirmed) {
      this.confirmed = false;
      return;
    }

    if (this.#hasErrors() || !this.#hasCustomPrompt() || this.#isDismissed()) {
      return;
    }

    event.preventDefault();
    if (this.hasDialogTarget) {
      if (this.hasDontShowAgainTarget) {
        this.dontShowAgainTarget.checked = false;
      }
      this.dialogTarget.showModal();
    }
  }

  confirmSave() {
    if (this.hasDontShowAgainTarget && this.dontShowAgainTarget.checked) {
      try {
        localStorage.setItem(this.storageKeyValue, "true");
      } catch (_) {
        // Ignore localStorage errors (e.g. private browsing)
      }
    }

    if (this.hasDialogTarget) {
      this.dialogTarget.close();
    }

    this.confirmed = true;
    if (this.hasFormTarget) {
      if (typeof this.formTarget.requestSubmit === "function") {
        this.formTarget.requestSubmit();
      } else {
        this.formTarget.submit();
      }
    }
  }

  #hasErrors() {
    if (!this.hasFormTarget) return false;

    // Skip confirmation if any field exceeds the character limit
    if (this.formTarget.querySelector(".text-destructive")) {
      return true;
    }

    const textareas = this.formTarget.querySelectorAll("textarea");
    for (const textarea of textareas) {
      if (Array.from(textarea.value).length > this.maxLengthValue) {
        return true;
      }
    }

    const prompts = this.formTarget.querySelectorAll(
      "input[type=hidden][data-ai-prompt-editor-target='prompt']",
    );
    for (const prompt of prompts) {
      if (Array.from(prompt.value || "").length > this.maxLengthValue) {
        return true;
      }
    }

    return false;
  }

  #hasCustomPrompt() {
    if (!this.hasFormTarget) return false;

    const prompts = this.formTarget.querySelectorAll(
      "input[type=hidden][data-ai-prompt-editor-target='prompt']",
    );
    return Array.from(prompts).some(
      (prompt) => (prompt.value || "").trim().length > 0,
    );
  }

  #isDismissed() {
    try {
      return localStorage.getItem(this.storageKeyValue) === "true";
    } catch (_) {
      return false;
    }
  }
}
