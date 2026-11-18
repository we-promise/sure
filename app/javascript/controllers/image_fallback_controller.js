import { Controller } from "@hotwired/stimulus";

// Removes an <img> the browser cannot load, revealing the fallback rendered
// underneath it. This replaces an inline onerror handler, which the
// Content-Security-Policy blocks.
export default class extends Controller {
  connect() {
    // The image may have failed before Stimulus connected, in which case its
    // error event is already gone. decode() rejects for a broken image and
    // resolves for one that loaded (including SVGs without a natural size).
    if (this.element.complete) {
      this.element.decode().catch(() => this.remove());
    }
  }

  remove() {
    this.element.remove();
  }
}
