import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["image", "fallback"];

  connect() {
    // An image can fail before Stimulus connects (including a cached failure).
    if (this.hasImageTarget && this.imageTarget.complete) {
      if (this.imageTarget.naturalWidth === 0) {
        this.showFallback();
      } else {
        this.showImage();
      }
    }
  }

  showFallback() {
    if (this.hasImageTarget) this.imageTarget.hidden = true;
    this.fallbackTarget.hidden = false;
  }

  showImage() {
    this.imageTarget.hidden = false;
    this.fallbackTarget.hidden = true;
  }
}
