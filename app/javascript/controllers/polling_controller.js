import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="polling"
// Automatically refreshes a turbo frame at a specified interval
export default class extends Controller {
  static values = {
    url: String,
    interval: { type: Number, default: 3000 },
  };

  connect() {
    this.startPolling();
  }

  disconnect() {
    this.stopPolling();
  }

  startPolling() {
    if (!this.hasUrlValue) return;

    this.poll = setInterval(() => {
      this.refresh();
    }, this.intervalValue);
  }

  stopPolling() {
    if (this.poll) {
      clearInterval(this.poll);
      this.poll = null;
    }
  }

  async refresh() {
    try {
      const response = await fetch(this.urlValue, {
        headers: {
          Accept: "text/html",
          "Turbo-Frame": this.element.id,
        },
      });

      if (response.ok) {
        const html = await response.text();
        const template = document.createElement("template");
        template.innerHTML = html;

        const newFrame = template.content.querySelector(
          `turbo-frame#${this.element.id}`,
        );
        if (newFrame) {
          this.element.innerHTML = newFrame.innerHTML;

          // Check if we should stop polling (no more pending/processing exports)
          if (!newFrame.hasAttribute("data-polling-url-value")) {
            this.stopPolling();
          }
        }
      }
    } catch (error) {
      console.error("Polling error:", error);
    }
  }
}
