import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static values = {
    url: String,
    interval: { type: Number, default: 1000 },
    maxRetryDelay: { type: Number, default: 8000 },
    // Give the server a short grace period to recognize the expired login and
    // replace the stale waiting state with the retry action.
    timeout: { type: Number, default: 125000 },
  };

  connect() {
    this.startedAt = Date.now();
    this.stopped = false;
    this.retryCount = 0;
    this.schedulePoll(0);
  }

  disconnect() {
    this.stopped = true;
    clearTimeout(this.timer);
  }

  schedulePoll(delay) {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.poll(), delay);
  }

  async poll() {
    if (this.stopped || this.polling) return;
    this.polling = true;

    const csrfToken = document.querySelector(
      "meta[name='csrf-token']",
    )?.content;
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          Accept: "text/vnd.turbo-stream.html",
          "X-CSRF-Token": csrfToken || "",
          "X-Requested-With": "XMLHttpRequest",
        },
        credentials: "same-origin",
        body: new URLSearchParams({ authenticity_token: csrfToken || "" }),
      });

      if (response.ok) {
        this.retryCount = 0;
        Turbo.renderStreamMessage(await response.text());
      } else {
        this.retryCount += 1;
        console.warn(
          `[Trade Republic] login poll failed with HTTP ${response.status}`,
        );
      }
    } catch (error) {
      this.retryCount += 1;
      console.warn("[Trade Republic] login poll request failed", error);
    } finally {
      this.polling = false;
      if (!this.stopped && Date.now() - this.startedAt < this.timeoutValue) {
        this.schedulePoll(
          this.retryCount > 0 ? this.retryDelay() : this.intervalValue,
        );
      }
    }
  }

  retryDelay() {
    return Math.min(
      this.intervalValue * 2 ** Math.min(this.retryCount - 1, 4),
      this.maxRetryDelayValue,
    );
  }
}
