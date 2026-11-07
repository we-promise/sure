import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["source", "status"];
  static values = { copied: String, fallback: String };

  async copy() {
    try {
      await navigator.clipboard.writeText(this.sourceTarget.value);
      this.statusTarget.textContent = this.copiedValue;
    } catch {
      this.sourceTarget.focus();
      this.sourceTarget.select();
      this.statusTarget.textContent = this.fallbackValue;
    }
  }
}
