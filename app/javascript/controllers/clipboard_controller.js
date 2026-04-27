import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["source"];

  copy(event) {
    event.preventDefault();
    if (this.sourceTarget?.textContent) {
      navigator.clipboard
        .writeText(this.sourceTarget.textContent)
        .then(() => {})
        .catch((error) => {
          console.error("Failed to copy text: ", error);
        });
    }
  }
}
