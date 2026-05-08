import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="polling"
// Automatically refreshes a turbo frame at a specified interval
export default class extends Controller {
  static values = {
    url: String,
    interval: { type: Number, default: 3000 },
    frameId: String,
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
      const frame = this.frameElement();
      if (!frame) {
        this.stopPolling();
        return;
      }

      const response = await fetch(this.urlValue, {
        headers: {
          Accept: "text/html",
          "Turbo-Frame": frame.id,
        },
      });

      if (response.ok) {
        const html = await response.text();
        const template = document.createElement("template");
        template.innerHTML = html;

        const newFrame = template.content.querySelector(
          `turbo-frame#${this.cssEscape(frame.id)}`,
        );
        if (newFrame) {
          if (frame === this.element) {
            this.syncPollingAttributes(newFrame);
          }
          frame.innerHTML = newFrame.innerHTML;

          // Check if we should stop polling (no more pending/processing exports)
          if (
            frame === this.element &&
            !newFrame.hasAttribute("data-polling-url-value")
          ) {
            this.stopPolling();
          }
        }
      }
    } catch (error) {
      console.error("Polling error:", error);
    }
  }

  frameElement() {
    if (this.hasFrameIdValue) {
      return document.getElementById(this.frameIdValue);
    }

    if (this.element.tagName.toLowerCase() === "turbo-frame") {
      return this.element;
    }

    return this.element.closest("turbo-frame");
  }

  cssEscape(value) {
    if (window.CSS?.escape) return CSS.escape(value);

    return value.replaceAll('"', '\\"');
  }

  syncPollingAttributes(newFrame) {
    const pollingUrl = newFrame.getAttribute("data-polling-url-value");
    const pollingInterval = newFrame.getAttribute(
      "data-polling-interval-value",
    );

    if (pollingUrl) {
      this.element.setAttribute("data-polling-url-value", pollingUrl);
    } else {
      this.element.removeAttribute("data-polling-url-value");
    }

    if (pollingInterval) {
      this.element.setAttribute("data-polling-interval-value", pollingInterval);
    } else {
      this.element.removeAttribute("data-polling-interval-value");
    }
  }
}
