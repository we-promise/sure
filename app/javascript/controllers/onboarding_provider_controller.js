import { Controller } from "@hotwired/stimulus";

// Turbo can restore another controller while an earlier explicit save is pending.
let pendingRequest = null;
const REQUEST_TIMEOUT_MS = 30_000;

export default class extends Controller {
  static targets = [
    "provider",
    "key",
    "keyLabel",
    "model",
    "modelFields",
    "button",
    "status",
  ];
  static values = { url: String, options: Object, messages: Object };

  connect() {
    this.requestId = (this.requestId || 0) + 1;
    this.resetControls();
    this.changeProvider();
    if (pendingRequest) {
      const requestId = this.requestId;
      this.lockControls();
      this.showStatus("checking");
      const release = () => {
        if (requestId !== this.requestId) return;
        this.resetControls();
        this.showStatus("request_failed", true);
      };
      pendingRequest.then(release, release);
    }
  }

  clearKey() {
    this.keyTarget.value = "";
  }

  beforeCache() {
    const pending = this.saving;
    this.requestId += 1;
    this.clearKey();
    this.resetControls();
    this.showStatus(pending ? "request_failed" : "unchecked", pending);
  }

  disconnect() {
    this.beforeCache();
  }

  modeChanged(event) {
    if (
      event.target.name === "user[onboarding_ai_mode]" &&
      event.target.form === this.element.closest("form") &&
      event.target.value !== "builtin"
    ) {
      this.clearKey();
    }
  }

  resetControls() {
    this.saving = false;
    this.providerTarget.disabled = false;
    this.keyTarget.disabled = false;
    this.buttonTarget.disabled = false;
    this.updateModelField();
    this.setContinueDisabled(false);
  }

  lockControls() {
    this.saving = true;
    this.buttonTarget.disabled = true;
    this.providerTarget.disabled = true;
    this.keyTarget.disabled = true;
    this.updateModelField();
    this.setContinueDisabled(true);
  }

  setContinueDisabled(disabled) {
    const button = this.element
      .closest("form")
      ?.querySelector('[type="submit"]');
    if (button) button.disabled = disabled;
  }

  changeProvider() {
    this.keyTarget.value = "";
    const option = this.optionsValue[this.providerTarget.value];
    this.keyLabelTarget.textContent = option.label;
    this.keyTarget.placeholder = option.placeholder;
    this.updateModelField();
    this.showStatus("unchecked");
  }

  updateModelField() {
    const openrouter = this.providerTarget.value === "openrouter";
    this.modelFieldsTarget.hidden = !openrouter;
    this.modelTarget.disabled = this.saving || !openrouter;
  }

  editModel() {
    this.showStatus("unchecked");
  }

  editKey() {
    this.showStatus("unchecked");
  }

  async save(event) {
    event.preventDefault();
    if (pendingRequest || this.saving || this.buttonTarget.matches(":disabled"))
      return;
    if (!this.keyTarget.value.trim()) {
      this.showStatus("missing_key", true);
      this.keyTarget.focus();
      return;
    }

    const openrouter = this.providerTarget.value === "openrouter";
    if (openrouter && !this.modelTarget.value.trim()) {
      this.showStatus("missing_model", true);
      this.modelTarget.focus();
      return;
    }

    const requestId = ++this.requestId;
    this.lockControls();
    this.showStatus("checking");

    const abortController = new AbortController();
    let timeout;
    let timedOut = false;
    try {
      const csrfToken = document.querySelector(
        'meta[name="csrf-token"]',
      )?.content;
      const request = fetch(this.urlValue, {
        method: "POST",
        signal: abortController.signal,
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          ...(csrfToken ? { "X-CSRF-Token": csrfToken } : {}),
        },
        body: JSON.stringify({
          ai_configuration: {
            provider: this.providerTarget.value,
            api_key: this.keyTarget.value,
            ...(openrouter ? { model: this.modelTarget.value.trim() } : {}),
          },
        }),
      }).then(async (response) => ({
        response,
        result: await response.json(),
      }));
      const deadline = new Promise((_, reject) => {
        timeout = setTimeout(() => {
          timedOut = true;
          abortController.abort();
          reject(new Error("Provider request timed out"));
        }, REQUEST_TIMEOUT_MS);
      });
      pendingRequest = Promise.race([request, deadline]);
      const { response, result } = await pendingRequest;
      if (requestId !== this.requestId) return;
      if (response.ok && result.status === "saved") {
        this.showStatus("saved");
      } else {
        this.showStatus(
          response.status === 403 ? "unauthorized" : result.error,
          true,
        );
      }
    } catch {
      if (requestId === this.requestId) {
        this.showStatus(timedOut ? "timed_out" : "request_failed", true);
      }
    } finally {
      clearTimeout(timeout);
      pendingRequest = null;
      if (requestId === this.requestId) {
        this.clearKey();
        this.resetControls();
      }
    }
  }

  showStatus(key, failed = false) {
    this.statusTarget.textContent =
      this.messagesValue[key] || this.messagesValue.request_failed;
    this.statusTarget.classList.toggle("text-destructive", failed);
    this.statusTarget.classList.toggle("text-secondary", !failed);
  }
}
