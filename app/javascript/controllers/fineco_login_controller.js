import { Controller } from "@hotwired/stimulus";

const terminalStates = new Set([
  "captured",
  "stopped",
  "expired",
  "failed",
  "rejected",
]);

export default class extends Controller {
  static targets = [
    "cancelButton",
    "error",
    "status",
    "viewer",
    "investmentsLink",
  ];

  static values = {
    enabled: Boolean,
    novncBase: String,
    startUrl: String,
    statusUrl: String,
    stopUrl: String,
    streamPath: String,
    statusWaiting: String,
    statusVerifying: String,
    statusStopping: String,
    statusSetupVerificationRequired: String,
    statusConnected: String,
    statusExpired: String,
    statusStopped: String,
    statusFailed: String,
    statusUnknown: String,
  };

  connect() {
    this.active = true;
    this.flowId = null;
    this.rfb = null;
    this.pollTimer = null;
    this.pollingFlowIds = new Set();
    this.starting = false;
    this.stopping = false;
    this.onBeforeCache = () => {
      this.active = false;
      this.stopFlow({ keepalive: true, silent: true });
    };
    document.addEventListener("turbo:before-cache", this.onBeforeCache);
  }

  disconnect() {
    this.active = false;
    document.removeEventListener("turbo:before-cache", this.onBeforeCache);
    this.stopFlow({ keepalive: true, silent: true });
    this.disconnectViewer();
  }

  async start(event) {
    event.preventDefault();
    if (!this.enabledValue || this.starting || this.flowId) return;

    this.starting = true;
    this.clearError();
    this.setStatus(this.statusWaitingValue);

    try {
      const response = await fetch(this.startUrlValue, {
        method: "POST",
        credentials: "same-origin",
        headers: this.requestHeaders,
        cache: "no-store",
      });
      const result = await this.readJson(response);
      if (!/^[A-Za-z0-9_-]{1,128}$/.test(result.flow_id || "")) {
        throw new Error("invalid flow");
      }

      this.flowId = result.flow_id;
      const startedFlowId = this.flowId;
      if (this.hasInvestmentsLinkTarget)
        this.investmentsLinkTarget.hidden = true;
      if (!this.active) {
        await this.stopFlow({ keepalive: true, silent: true });
        return;
      }
      if (this.applyStatus(result.state)) return;

      const viewerStarted = await this.connectViewer(startedFlowId);
      if (!viewerStarted || !this.active || this.flowId !== startedFlowId) {
        if (this.flowId === startedFlowId)
          await this.stopFlow({ keepalive: true, silent: true });
        return;
      }
      this.cancelButtonTarget.hidden = false;
      this.poll();
    } catch (_error) {
      if (this.flowId) await this.stopFlow({ silent: true });
      this.showError(this.statusUnknownValue);
    } finally {
      this.starting = false;
    }
  }

  async stop(event) {
    event?.preventDefault();
    await this.stopFlow();
  }

  async poll() {
    const flowId = this.flowId;
    if (!this.active || !flowId || this.pollingFlowIds.has(flowId)) return;

    this.pollingFlowIds.add(flowId);
    try {
      const url = new URL(this.statusUrlValue, window.location.origin);
      url.searchParams.set("id", flowId);
      const response = await fetch(url, {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
        cache: "no-store",
      });
      const result = await this.readJson(response);
      if (this.active && this.flowId === flowId) this.applyStatus(result.state);
    } catch (_error) {
      if (this.active && this.flowId === flowId) {
        this.showError(this.statusUnknownValue);
        this.stopPolling();
      }
    } finally {
      this.pollingFlowIds.delete(flowId);
    }

    if (this.active && this.flowId === flowId)
      this.pollTimer = window.setTimeout(() => this.poll(), 2000);
  }

  async connectViewer(expectedFlowId) {
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(expectedFlowId || "")) {
      throw new Error("invalid flow");
    }

    const { default: RFB } = await import(`${this.novncBaseValue}core/rfb.js`);
    if (!this.active || this.flowId !== expectedFlowId) return false;

    const socketUrl = new URL(this.streamPathValue, window.location.origin);
    socketUrl.protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    socketUrl.searchParams.set("id", this.flowId);

    this.viewerTarget.classList.remove("hidden");
    this.viewerTarget.dataset.connected = "false";
    this.rfb = new RFB(this.viewerTarget, socketUrl.toString(), {});
    this.rfb.scaleViewport = true;
    this.rfb.resizeSession = true;
    this.rfb.showDotCursor = true;
    this.rfb.addEventListener("connect", () => {
      if (this.active && this.flowId === expectedFlowId)
        this.viewerTarget.dataset.connected = "true";
    });
    this.rfb.addEventListener("disconnect", () => {
      this.viewerTarget.dataset.connected = "false";
    });
    return true;
  }

  applyStatus(state) {
    const statusMessages = {
      starting: this.statusWaitingValue,
      awaiting_login: this.statusWaitingValue,
      capturing: this.statusVerifyingValue,
      stopping: this.statusStoppingValue,
      setup_verification_required: this.statusSetupVerificationRequiredValue,
      captured: this.statusConnectedValue,
      stopped: this.statusStoppedValue,
      expired: this.statusExpiredValue,
      failed: this.statusFailedValue,
      rejected: this.statusFailedValue,
    };
    const normalizedState = String(state || "");
    const message = statusMessages[normalizedState] || this.statusUnknownValue;
    this.setStatus(message);

    if (this.hasInvestmentsLinkTarget) {
      this.investmentsLinkTarget.hidden = normalizedState !== "captured";
    }

    if (terminalStates.has(normalizedState)) {
      this.stopPolling();
      this.flowId = null;
      this.cancelButtonTarget.hidden = true;
      this.disconnectViewer();
      return true;
    }

    return false;
  }

  async stopFlow({ keepalive = false, silent = false } = {}) {
    if (!this.flowId || this.stopping) return;

    this.stopping = true;
    const flowId = this.flowId;
    this.stopPolling();
    this.disconnectViewer();
    if (this.hasCancelButtonTarget) this.cancelButtonTarget.hidden = true;

    try {
      const url = new URL(this.stopUrlValue, window.location.origin);
      url.searchParams.set("id", flowId);
      const response = await fetch(url, {
        method: "DELETE",
        credentials: "same-origin",
        headers: this.requestHeaders,
        cache: "no-store",
        keepalive,
      });
      const result = await this.readJson(response);
      const state = String(result.state || "");
      const terminal = terminalStates.has(state);
      if (!silent) this.applyStatus(state);
      else if (terminal && this.flowId === flowId) this.flowId = null;

      if (!terminal && this.active && this.flowId === flowId) {
        this.pollTimer = window.setTimeout(() => this.poll(), 1000);
      }
    } catch (_error) {
      if (!silent) this.showError(this.statusUnknownValue);
    } finally {
      this.stopping = false;
    }
  }

  async readJson(response) {
    if (!response.ok) throw new Error("request failed");
    return response.json();
  }

  get requestHeaders() {
    return {
      Accept: "application/json",
      "X-CSRF-Token":
        document.querySelector('meta[name="csrf-token"]')?.content || "",
    };
  }

  setStatus(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message;
  }

  showError(message) {
    if (!this.hasErrorTarget) return;
    this.errorTarget.textContent = message;
    this.errorTarget.classList.remove("hidden");
  }

  clearError() {
    if (!this.hasErrorTarget) return;
    this.errorTarget.textContent = "";
    this.errorTarget.classList.add("hidden");
  }

  stopPolling() {
    if (this.pollTimer) window.clearTimeout(this.pollTimer);
    this.pollTimer = null;
  }

  disconnectViewer() {
    if (this.rfb) {
      this.rfb.disconnect();
      this.rfb = null;
    }
    if (this.hasViewerTarget) this.viewerTarget.dataset.connected = "false";
    if (this.hasViewerTarget) this.viewerTarget.replaceChildren();
  }
}
