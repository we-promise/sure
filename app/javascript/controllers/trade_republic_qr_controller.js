import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["button", "label", "panel", "code", "status"];
  static values = {
    initiateUrl: String,
    pollUrl: String,
    cancelUrl: String,
    returnUrl: String,
    autoPoll: { type: Boolean, default: false },
    loadingText: String,
    instructionText: String,
    successText: String,
    errorText: String,
    interval: { type: Number, default: 1000 },
    timeout: { type: Number, default: 120000 },
    maxRetryDelay: { type: Number, default: 8000 },
    loginText: String,
    cancelText: String,
  };

  connect() {
    this.polling = false;
    this.stopped = false;
    this.pollRequest = null;
    this.retryCount = 0;
    if (this.autoPollValue) {
      this.polling = true;
      this.startedAt = Date.now();
      this.panelTarget.hidden = false;
      this.setButtonLabel(this.cancelTextValue);
      this.statusTarget.textContent = this.instructionTextValue;
      this.poll();
    }
  }

  disconnect() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.pollRequest?.abort();
  }

  async start(event) {
    event.preventDefault();
    if (this.polling) return;

    this.stopped = false;
    this.polling = true;
    this.retryCount = 0;
    this.startedAt = Date.now();
    this.panelTarget.hidden = false;
    this.setButtonLabel(this.cancelTextValue);
    this.codeTarget.replaceChildren();
    this.statusTarget.textContent = this.loadingTextValue;

    try {
      const response = await fetch(this.initiateUrlValue, {
        method: "POST",
        headers: { ...this.headers(), Accept: "text/vnd.turbo-stream.html" },
        credentials: "same-origin",
        body: this.body(),
      });
      if (!response.ok)
        throw new Error(`QR login initiation failed: ${response.status}`);

      const result = await response.json();
      this.renderQr(result);

      await this.poll();
    } catch (error) {
      this.showError(error);
    }
  }

  async poll() {
    if (this.stopped) return;

    try {
      this.pollRequest?.abort();
      this.pollRequest = new AbortController();
      const response = await fetch(this.pollUrlValue, {
        method: "POST",
        headers: { ...this.headers(), Accept: "application/json" },
        credentials: "same-origin",
        body: this.body(),
        signal: this.pollRequest.signal,
      });
      const result = await this.jsonResponse(response);
      if (!response.ok) {
        const error = new Error(result.error || "QR login failed");
        error.retryable =
          result.retryable === true || this.retryableStatus(response.status);
        throw error;
      }

      this.retryCount = 0;
      this.renderQr(result);

      if (result.status !== "pending") {
        this.statusTarget.textContent = this.successTextValue;
        window.Turbo.visit(this.returnUrlValue);
        return;
      }

      this.schedulePoll(this.nextPollDelay(result));
    } catch (error) {
      if (this.stopped || error.name === "AbortError") return;

      if (
        this.isRetryableError(error) &&
        Date.now() - this.startedAt < this.timeoutValue
      ) {
        this.retryCount += 1;
        this.schedulePoll(this.retryDelay());
      } else {
        this.showError(error);
      }
    } finally {
      this.pollRequest = null;
    }
  }

  schedulePoll(delay) {
    clearTimeout(this.timer);
    if (this.stopped) return;

    if (Date.now() - this.startedAt >= this.timeoutValue) {
      this.showError(new Error("QR login expired"));
      return;
    }

    this.timer = setTimeout(() => this.poll(), delay);
  }

  retryDelay() {
    return Math.min(
      this.intervalValue * 2 ** Math.min(this.retryCount - 1, 4),
      this.maxRetryDelayValue,
    );
  }

  retryableStatus(status) {
    return status === 408 || status === 425 || status === 429 || status >= 500;
  }

  isRetryableError(error) {
    return error.retryable === true || error.name === "TypeError";
  }

  async jsonResponse(response) {
    try {
      return await response.json();
    } catch {
      const error = new Error(
        `QR login returned invalid JSON: ${response.status}`,
      );
      error.retryable = this.retryableStatus(response.status);
      throw error;
    }
  }

  showError(error) {
    if (this.stopped) return;
    console.warn("[Trade Republic] QR login failed", error);
    this.polling = false;
    this.setButtonLabel(this.loginTextValue);
    this.buttonTarget.disabled = false;
    this.statusTarget.textContent = this.errorTextValue;
  }

  toggle(event) {
    event.preventDefault();
    if (this.polling) {
      this.hideQr();
    } else {
      this.start(event);
    }
  }

  async hideQr() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.pollRequest?.abort();
    this.polling = false;
    this.panelTarget.hidden = true;
    this.codeTarget.replaceChildren();
    this.buttonTarget.disabled = false;

    try {
      const response = await fetch(this.cancelUrlValue, {
        method: "POST",
        headers: this.headers(),
        credentials: "same-origin",
        body: this.body(),
      });
      if (!response.ok)
        throw new Error(`QR login cancellation failed: ${response.status}`);

      Turbo.renderStreamMessage(await response.text());
    } catch (error) {
      this.stopped = false;
      console.warn("[Trade Republic] QR login cancellation failed", error);
    }
  }

  renderQr(result) {
    if (!result.qr_code_svg) return;
    this.codeTarget.innerHTML = result.qr_code_svg;
    this.statusTarget.textContent = this.instructionTextValue;
  }

  nextPollDelay(result) {
    const expiresAt = result.qr_code_token_expires_at;
    if (!expiresAt) return this.intervalValue;

    const remaining = Date.parse(expiresAt) - Date.now();
    return remaining > 0 && remaining <= 1500 ? 100 : this.intervalValue;
  }

  setButtonLabel(label) {
    if (this.hasLabelTarget) this.labelTarget.textContent = label;
  }

  headers() {
    return {
      Accept: "application/json",
      "X-CSRF-Token":
        document.querySelector("meta[name='csrf-token']")?.content || "",
      "X-Requested-With": "XMLHttpRequest",
    };
  }

  body() {
    const csrfToken =
      document.querySelector("meta[name='csrf-token']")?.content || "";
    return new URLSearchParams({ authenticity_token: csrfToken });
  }
}
