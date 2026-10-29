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
          this.subscriptionIdValue && this.subscription ? "enabled" : "disabled");
      } catch {
        this.setStatus("request");
      }
    }
    this.busy = false;
    this.updateControls();
  }

  disconnect() {
    this.stopPolling();
  }

  async enable() {
    await this.run(async () => {
      // Request permission before awaiting any other work: Safari requires the
      // permission request to retain this button's direct user activation.
      const permission = Notification.permission === "granted" ? "granted" :
        await Notification.requestPermission();
      if (permission !== "granted") {
        this.setStatus(permission === "denied" ? "denied" : "permission");
        return;
      }
      await navigator.serviceWorker.ready;
      this.subscription = await this.registration.pushManager.getSubscription() ||
        await this.registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: this.applicationServerKey(),
        });
      const subscription = this.subscription.toJSON();
      const result = await this.request(this.urlValue, "POST", {
        endpoint: subscription.endpoint,
        p256dh: subscription.keys.p256dh,
        auth: subscription.keys.auth,
      });
      this.subscriptionIdValue = result.id;
      this.setStatus("enabled");
    });
  }

  async disable() {
    await this.run(async () => {
      this.stopPolling();
      if (this.subscriptionIdValue) await this.request(this.deviceUrl(), "DELETE");
      this.subscriptionIdValue = "";
      if (this.subscription) await this.subscription.unsubscribe();
      this.subscription = null;
      this.setStatus("disabled");
    });
  }

  async test() {
    await this.run(async () => {
      await this.request(`${this.deviceUrl()}/test_notification`, "POST");
      this.setStatus("queued");
      this.pollCount = 0;
      this.stopPolling();
      this.pollTimer = setTimeout(() => this.pollTest(), 1500);
    });
  }

  async pollTest() {
    try {
      const result = await this.request(this.deviceUrl(), "GET");
      const status = result.test_status || "pending";
      this.setStatus(status);
      if (status === "pending" && ++this.pollCount < 20) {
        this.pollTimer = setTimeout(() => this.pollTest(), 1500);
      } else if (status === "pending") {
        this.setStatus("expired");
      }
    } catch (error) {
      this.statusTarget.textContent = error.userMessage || this.messagesValue.request;
    }
  }

  async run(action) {
    if (this.busy) return;
    this.busy = true;
    this.updateControls();
    try {
      await action();
    } catch (error) {
      this.statusTarget.textContent = error.userMessage || this.messagesValue.request;
    } finally {
      this.busy = false;
      this.updateControls();
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
    if (response.status === 404) {
      this.subscriptionIdValue = "";
      this.updateControls();
    }
    const result = await response.json();
    if (!response.ok) {
      const error = new Error("Browser notification request failed");
      error.userMessage = result.error || this.messagesValue.request;
      throw error;
    }
    return result;
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
    clearTimeout(this.pollTimer);
  }

  updateControls() {
    const available = Boolean(this.supported && this.publicKeyValue && this.registration);
    const enabled = Boolean(this.subscriptionIdValue && this.subscription);
    this.enableTarget.disabled = this.busy || !available || enabled;
    this.disableTarget.disabled = this.busy || !enabled;
    this.testTarget.disabled = this.busy || !available || !enabled;
  }
}
