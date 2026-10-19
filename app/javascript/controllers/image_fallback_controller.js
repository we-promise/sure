import { Controller } from "@hotwired/stimulus";

// Shows the fallback rendered next to an image when the browser cannot load
// the image, and the image again if a later source loads.
export default class extends Controller {
  static targets = ["image", "fallback"];

  // An image can fail before the controller connects, a cached 404 for
  // example, so its error event is already gone.
  connect() {
    if (this.imageTarget.complete && this.imageTarget.naturalWidth === 0) {
      this.showFallback();
    }
  }

  showFallback() {
    this.imageTarget.classList.add("hidden");
    this.fallbackTarget.classList.remove("hidden");
  }

  showImage() {
    this.imageTarget.classList.remove("hidden");
    this.fallbackTarget.classList.add("hidden");
  }
}
