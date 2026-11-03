import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["status", "enable", "disable", "test", "iosGuidance"];
  static values = {
    publicKey: String,
    subscriptionId: String,
    registrations: Object,
    url: String,
    messages: Object,
  };

  async connect() {
    this.lifecycleGeneration = (this.lifecycleGeneration || 0) + 1;
    this.pollGeneration = (this.pollGeneration || 0) + 1;
    this.busy = true;
    this.subscriptionIdValue = "";
    this.supported = window.isSecureContext && "serviceWorker" in navigator &&
      "PushManager" in window && "Notification" in window;
    const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
      (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
    const standalone = window.matchMedia("(display-mode: standalone)").matches || navigator.standalone;
    this.iosGuidanceTarget.classList.toggle("hidden", !ios || standalone);
    if (!this.supported || (ios && !standalone)) {
      this.supported = false;
      this.setStatus("unsupported");
    } else {
      try {
        this.registration = await navigator.serviceWorker.getRegistration("/") ||
          await navigator.serviceWorker.register("/service-worker");
        this.subscription = await this.registration.pushManager.getSubscription();
        if (this.subscription) {
          const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(this.subscription.endpoint));
          const digest = Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("");
          this.subscriptionIdValue = Object.entries(this.registrationsValue)
            .find(([, registeredDigest]) => registeredDigest === digest)?.[0] || "";
        }
        this.setStatus(!this.publicKeyValue ? "unconfigured" :
          Notification.permission === "denied" ? "denied" :
          this.subscriptionIdValue && this.subscriptionUsesCurrentKey(this.subscription) ? "enabled" : "disabled");
      } catch {
        this.setStatus("request");
      }
    }
    this.busy = false;
    this.updateControls();
  }

  disconnect() {
    this.lifecycleGeneration++;
    this.stopPolling();
  }

  async enable() {
    await this.run(async (isCurrent) => {
      // Request permission before awaiting any other work: Safari requires the
      // permission request to retain this button's direct user activation.
      const permission = Notification.permission === "granted" ? "granted" :
        await Notification.requestPermission();
      if (!isCurrent()) return;
      if (permission !== "granted") {
        this.setStatus(permission === "denied" ? "denied" : "permission");
        return;
      }
      await navigator.serviceWorker.ready;
      if (!isCurrent()) return;
      const currentSubscription = await this.registration.pushManager.getSubscription();
      if (!isCurrent()) return;
      this.subscription = currentSubscription;
      if (this.subscription && !this.subscriptionUsesCurrentKey(this.subscription)) {
        if (this.subscriptionIdValue) await this.request(this.deviceUrl(), "DELETE");
        if (!isCurrent()) return;
        this.subscriptionIdValue = "";
        const unsubscribed = await this.subscription.unsubscribe();
        if (!isCurrent()) return;
        if (!unsubscribed) throw new Error("Browser subscription replacement failed");
        this.subscription = null;
      }
      const browserSubscription = this.subscription || await this.registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: this.applicationServerKey(),
      });
      if (!isCurrent()) return;
      this.subscription = browserSubscription;
      const subscription = this.subscription.toJSON();
      const result = await this.request(this.urlValue, "POST", {
        endpoint: subscription.endpoint,
        p256dh: subscription.keys.p256dh,
        auth: subscription.keys.auth,
      });
      if (!isCurrent()) return;
      this.subscriptionIdValue = result.id;
      this.setStatus("enabled");
    });
  }

  async disable() {
    await this.run(async (isCurrent) => {
      this.stopPolling();
      if (this.subscriptionIdValue) await this.request(this.deviceUrl(), "DELETE");
      if (!isCurrent()) return;
      this.subscriptionIdValue = "";
      if (this.subscription) await this.subscription.unsubscribe();
      if (!isCurrent()) return;
      this.subscription = null;
      this.setStatus("disabled");
    });
  }

  async test() {
    await this.run(async (isCurrent) => {
      this.stopPolling();
      await this.request(`${this.deviceUrl()}/test_notification`, "POST");
      if (!isCurrent()) return;
      this.setStatus("queued");
      this.pollCount = 0;
      this.pollTimer = setTimeout(() => this.pollTest(), 1500);
    });
  }

  async pollTest() {
    const generation = this.pollGeneration;
    try {
      const result = await this.request(this.deviceUrl(), "GET");
      if (generation !== this.pollGeneration) return;
      const status = result.test_status || "pending";
      this.setStatus(status);
      if (status === "pending" && ++this.pollCount < 20) {
        this.pollTimer = setTimeout(() => this.pollTest(), 1500);
      } else if (status === "pending") {
        this.setStatus("expired");
      }
    } catch (error) {
      if (generation !== this.pollGeneration) return;
      this.showError(error);
    }
  }

  async run(action) {
    if (this.busy) return;
    const generation = this.lifecycleGeneration;
    const isCurrent = () => generation === this.lifecycleGeneration;
    this.busy = true;
    this.updateControls();
    try {
      await action(isCurrent);
    } catch (error) {
      if (isCurrent()) this.showError(error);
    } finally {
      if (isCurrent()) {
        this.busy = false;
        this.updateControls();
      }
    }
  }

  async request(url, method, body) {
    const response = await fetch(url, {
      method,
      credentials: "same-origin",
      redirect: "error",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "",
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (response.status === 204) return {};
    if (response.status === 404 && method === "DELETE") return {};
    const result = await response.json();
    if (!response.ok) {
      const error = new Error("Browser notification request failed");
      error.status = response.status;
      error.userMessage = result.error || this.messagesValue.request;
      throw error;
    }
    return result;
  }

  showError(error) {
    if (error.status === 404) {
      this.subscriptionIdValue = "";
      this.updateControls();
    }
    this.statusTarget.textContent = error.userMessage || this.messagesValue.request;
  }

  subscriptionUsesCurrentKey(subscription) {
    const boundKey = subscription?.options?.applicationServerKey;
    if (!boundKey || !this.publicKeyValue) return false;
    const expected = this.applicationServerKey();
    const actual = new Uint8Array(boundKey);
    return actual.length === expected.length && expected.every((byte, index) => byte === actual[index]);
  }

  applicationServerKey() {
    const encoded = this.publicKeyValue.replace(/-/g, "+").replace(/_/g, "/");
    const decoded = atob(encoded.padEnd(Math.ceil(encoded.length / 4) * 4, "="));
    return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
  }

  deviceUrl() {
    return `${this.urlValue}/${this.subscriptionIdValue}`;
  }

  setStatus(key) {
    this.statusTarget.textContent = this.messagesValue[key] || this.messagesValue.request;
  }

  stopPolling() {
    this.pollGeneration++;
    clearTimeout(this.pollTimer);
  }

  updateControls() {
    const available = Boolean(this.supported && this.publicKeyValue && this.registration);
    const registered = Boolean(this.subscriptionIdValue && this.subscription);
    const enabled = registered && this.subscriptionUsesCurrentKey(this.subscription);
    this.enableTarget.disabled = this.busy || !available || enabled;
    this.disableTarget.disabled = this.busy || !registered;
    this.testTarget.disabled = this.busy || !available || !enabled;
  }
}
