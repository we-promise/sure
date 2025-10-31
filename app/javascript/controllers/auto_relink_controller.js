import { Controller } from "@hotwired/stimulus";

// Auto opens the SimpleFin relink modal when provided a URL.
// Usage in view (ERB):
//   <div data-controller="auto-relink" data-auto-relink-url-value="<%= relink_simplefin_item_path(id) %>"></div>
// The controller will attempt to load the URL into the global `modal` turbo-frame.
// If the frame is missing, it will fallback to full navigation to the URL.
export default class extends Controller {
  static values = {
    url: String
  }

  connect() {
    if (!this.hasUrlValue) return;

    try {
      const frame = document.getElementById("modal");
      if (frame) {
        // Load into the modal frame so the page doesn't navigate away
        frame.src = this.urlValue;
      } else {
        // Fallback: navigate to the relink URL
        window.location.href = this.urlValue;
      }
    } catch (e) {
      // Last-resort fallback: navigate
      try { window.location.href = this.urlValue; } catch (_) {}
    }
  }
}
