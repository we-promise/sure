import { Controller } from "@hotwired/stimulus";
import { Turbo } from "@hotwired/turbo-rails";

export default class extends Controller {
  static targets = ["status", "error"];
  static values = {
    url: String,
    attempt: String,
    expires: String,
    failure: String,
  };

  connect() {
    this.stopped = false;
    this.pollCount = 0;
    this.timer = setTimeout(() => this.poll(), 10000);
  }

  disconnect() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.request?.abort();
  }

  async poll() {
    if (this.stopped) return;
    if (this.pollCount >= 30 || Date.now() >= Date.parse(this.expiresValue)) {
      this.fail(this.failureValue);
      return;
    }

    this.pollCount += 1;
    this.request = new AbortController();
    const timeout = setTimeout(() => this.request.abort(), 60000);
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')
            ?.content,
        },
        body: JSON.stringify({
          ca_auto_bank_login: { attempt_id: this.attemptValue },
        }),
        signal: this.request.signal,
      });
      if (this.stopped) return;
      const data = await response.json();
      if (!response.ok || data.state === "error") {
        this.fail(data.message || this.failureValue);
      } else if (data.state === "connected") {
        this.stopped = true;
        Turbo.visit(data.redirect_url);
      } else if (data.state === "pending") {
        this.timer = setTimeout(() => this.poll(), 10000);
      } else {
        this.fail(this.failureValue);
      }
    } catch {
      if (!this.stopped) this.fail(this.failureValue);
    } finally {
      clearTimeout(timeout);
    }
  }

  fail(message) {
    this.stopped = true;
    this.errorTarget.textContent = message;
    this.errorTarget.hidden = false;
    this.statusTarget.hidden = true;
  }
}
