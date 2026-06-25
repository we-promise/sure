import { Controller } from "@hotwired/stimulus";

// Single source of truth so the icon-swap and label-flash feedback last the
// same time when both copy buttons appear on one page.
const RESET_DELAY_MS = 2000;

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
      }, RESET_DELAY_MS);
      return;
    }

    // A single-icon button (e.g. DS::Button) has no icons to swap, so confirm
    // the copy by briefly flipping the button's own label.
    this.flashLabel(button);
  }

  flashLabel(button) {
    // DS::Button renders its icon as an <svg> and its text in `span.truncate`,
    // so scope to that class rather than the first <span> in case an icon ever
    // ships wrapped in a span.
    const label = button?.querySelector("span.truncate") ?? button?.querySelector("span");
    if (!label || !this.hasCopiedTextValue) return;

    clearTimeout(this.labelResetTimer);
    if (this.originalLabel == null) {
      this.originalLabel = label.textContent;
    }

    label.textContent = this.copiedTextValue;
    this.labelResetTimer = setTimeout(() => {
      label.textContent = this.originalLabel;
      this.originalLabel = null;
    }, RESET_DELAY_MS);
  }

  disconnect() {
    clearTimeout(this.labelResetTimer);
  }
}
