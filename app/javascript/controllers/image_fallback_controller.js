import { Controller } from "@hotwired/stimulus";

// Swaps a broken image for a rendered fallback so a broken <img> is never
// shown to the user. Covers every failure mode of an icon <img>:
//   - attachment row whose blob bytes are missing from storage (404)
//   - corrupt / non-decodable image bytes
//   - remote fallback URLs that fail (Brandfetch outage, favicon 404, ...)
//
// Usage:
//   <div data-controller="image-fallback">
//     <img data-image-fallback-target="image" ...>
//     <div data-image-fallback-target="fallback" class="hidden">...</div>
//   </div>
export default class extends Controller {
  static targets = ["image", "fallback"];

  #onError = null;

  connect() {
    this.#onError = () => this.#showFallback();

    // A cached 404 can finish loading (and erroring) before Stimulus
    // connects, so re-check the image state instead of relying on the
    // error event alone.
    if (this.imageTarget.complete && this.imageTarget.naturalWidth === 0) {
      this.#showFallback();
      return;
    }

    this.imageTarget.addEventListener("error", this.#onError);
  }

  disconnect() {
    if (this.#onError) {
      this.imageTarget.removeEventListener("error", this.#onError);
    }
  }

  #showFallback() {
    this.imageTarget.classList.add("hidden");
    if (this.hasFallbackTarget) {
      this.fallbackTarget.classList.remove("hidden");
    }
  }
}
