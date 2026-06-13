import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["source", "iconDefault", "iconSuccess"];
  static values = { copiedText: String };

  copy(event) {
    event.preventDefault();
    // Capture the button now: `event.currentTarget` is reset to null once the
    // event finishes dispatching, so it can't be read inside the async `.then`.
    const button = event.currentTarget;
    const text = this.sourceTarget?.textContent;
    if (!text) return;

    navigator.clipboard
      .writeText(text)
      .then(() => {
        this.showSuccess(button);
      })
      .catch((error) => {
        console.error("Failed to copy text: ", error);
      });
  }

  showSuccess(button) {
    // Markup that ships explicit default/success icons (invite codes, MFA,
    // profiles) toggles between them.
    if (this.hasIconDefaultTarget && this.hasIconSuccessTarget) {
      this.iconDefaultTarget.classList.add("hidden");
      this.iconSuccessTarget.classList.remove("hidden");
      setTimeout(() => {
        this.iconDefaultTarget.classList.remove("hidden");
        this.iconSuccessTarget.classList.add("hidden");
      }, 3000);
      return;
    }

    // A single-icon button (e.g. DS::Button) has no icons to swap, so confirm
    // the copy by briefly flipping the button's own label.
    this.flashLabel(button);
  }

  flashLabel(button) {
    const label = button?.querySelector("span");
    if (!label || !this.hasCopiedTextValue) return;

    clearTimeout(this.labelResetTimer);
    if (this.originalLabel == null) {
      this.originalLabel = label.textContent;
    }

    label.textContent = this.copiedTextValue;
    this.labelResetTimer = setTimeout(() => {
      label.textContent = this.originalLabel;
      this.originalLabel = null;
    }, 2000);
  }

  disconnect() {
    clearTimeout(this.labelResetTimer);
  }
}
