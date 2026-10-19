import { Controller } from "@hotwired/stimulus";
import { Turbo } from "@hotwired/turbo-rails";

export default class extends Controller {
  static targets = ["status", "error"];
  static values = {
    url: String,
    attempt: String,
    expires: String,
    pollInterval: Number,
    phase: String,
    deviceStatus: String,
    phoneStatus: String,
    retryingStatus: String,
    failure: String,
  };

  connect() {
    this.stopped = false;
    this.transportFailureCount = 0;
    this.schedulePoll();
  }

  disconnect() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.request?.abort();
  }

  schedulePoll() {
    if (this.stopped) return;

    const interval = Math.max(1000, this.pollIntervalValue * 1000);
    this.timer = setTimeout(() => this.poll(), interval);
  }

  async poll() {
    if (this.stopped) return;
    if (Date.now() >= Date.parse(this.expiresValue)) {
      this.fail(this.failureValue);
      return;
    }

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
          scalable_login: { attempt_id: this.attemptValue },
        }),
        signal: this.request.signal,
      });
      if (this.stopped) return;

      const data = await response.json().catch(() => null);
      if (!response.ok || data?.state === "error") {
        this.fail(data?.message || this.failureValue);
      } else if (!data) {
        this.fail(this.failureValue);
      } else if (data.state === "connected") {
        this.stopped = true;
        Turbo.visit(data.redirect_url);
      } else if (data.state === "pending") {
        this.transportFailureCount = 0;
        this.phaseValue = data.phase || this.phaseValue;
        this.expiresValue = data.expires_at || this.expiresValue;
        if (
          Number.isFinite(Number(data.poll_interval)) &&
          Number(data.poll_interval) > 0
        ) {
          this.pollIntervalValue = Number(data.poll_interval);
        }
        this.statusTarget.textContent =
          this.phaseValue === "phone_approval"
            ? this.phoneStatusValue
            : this.deviceStatusValue;
        this.schedulePoll();
      } else {
        this.fail(this.failureValue);
      }
    } catch {
      if (!this.stopped) {
        this.transportFailureCount += 1;
        this.statusTarget.textContent = this.retryingStatusValue;
        if (this.transportFailureCount <= 3) {
          const retryDelay = 1000 * 2 ** (this.transportFailureCount - 1);
          this.timer = setTimeout(() => this.poll(), retryDelay);
        } else {
          this.transportFailureCount = 0;
          this.schedulePoll();
        }
      }
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
