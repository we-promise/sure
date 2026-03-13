import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="plaid"
export default class extends Controller {
  static values = {
    linkToken: String,
    region: { type: String, default: "us" },
    isUpdate: { type: Boolean, default: false },
    itemId: String,
  };

  connect() {
    this._connectionToken = (this._connectionToken ?? 0) + 1;
    const connectionToken = this._connectionToken;
    this.open(connectionToken).catch((error) => {
      console.error("Failed to initialize Plaid Link", error);
    });
  }

  disconnect() {
    this._handler?.destroy();
    this._handler = null;
    this._connectionToken = (this._connectionToken ?? 0) + 1;
  }

  waitForPlaid() {
    if (typeof Plaid !== "undefined") {
      return Promise.resolve();
    }

    return new Promise((resolve, reject) => {
      let plaidScript = document.querySelector(
        'script[src*="link-initialize.js"]'
      );

      // Reject if the CDN request stalls without firing load or error
      const timeoutId = window.setTimeout(() => {
        if (plaidScript) plaidScript.dataset.plaidState = "error";
        reject(new Error("Timed out loading Plaid script"));
      }, 10_000);

      // Remove previously failed script so we can retry with a fresh element
      if (plaidScript?.dataset.plaidState === "error") {
        plaidScript.remove();
        plaidScript = null;
      }

      if (!plaidScript) {
        plaidScript = document.createElement("script");
        plaidScript.src = "https://cdn.plaid.com/link/v2/stable/link-initialize.js";
        plaidScript.async = true;
        plaidScript.dataset.plaidState = "loading";
        document.head.appendChild(plaidScript);
      }

      plaidScript.addEventListener("load", () => {
        window.clearTimeout(timeoutId);
        plaidScript.dataset.plaidState = "loaded";
        resolve();
      }, { once: true });
      plaidScript.addEventListener("error", () => {
        window.clearTimeout(timeoutId);
        plaidScript.dataset.plaidState = "error";
        reject(new Error("Failed to load Plaid script"));
      }, { once: true });

      // Re-check after attaching listeners in case the script loaded between
      // the initial typeof check and listener attachment (avoids a permanently
      // pending promise on retry flows).
      if (typeof Plaid !== "undefined") {
        window.clearTimeout(timeoutId);
        resolve();
      }
    });
  }

  async open(connectionToken = this._connectionToken) {
    await this.waitForPlaid();
    if (connectionToken !== this._connectionToken) return;

    this._handler = Plaid.create({
      token: this.linkTokenValue,
      onSuccess: this.handleSuccess,
      onLoad: this.handleLoad,
      onExit: this.handleExit,
      onEvent: this.handleEvent,
    });

    this._handler.open();
  }

  handleSuccess = (public_token, metadata) => {
    if (this.isUpdateValue) {
      // Trigger a sync to verify the connection and update status
      fetch(`/plaid_items/${this.itemIdValue}/sync`, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('[name="csrf-token"]').content,
        },
      }).then(() => {
        // Refresh the page to show the updated status
        window.location.href = "/accounts";
      });
      return;
    }

    // For new connections, create a new Plaid item
    fetch("/plaid_items", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector('[name="csrf-token"]').content,
      },
      body: JSON.stringify({
        plaid_item: {
          public_token: public_token,
          metadata: metadata,
          region: this.regionValue,
        },
      }),
    }).then((response) => {
      if (response.redirected) {
        window.location.href = response.url;
      }
    });
  };

  handleExit = (err, metadata) => {
    // If there was an error during update mode, refresh the page to show latest status
    if (err && metadata.status === "requires_credentials") {
      window.location.href = "/accounts";
    }
  };

  handleEvent = (eventName, metadata) => {
    // no-op
  };

  handleLoad = () => {
    // no-op
  };
}
