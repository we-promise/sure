import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="plaid"
export default class extends Controller {
  static targets = ["createFailed"];
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

    // For new connections, create a new Plaid item. The server answers with a
    // Turbo Stream: a redirect once the item exists, or -- when the institution is
    // already connected -- a warning for the modal frame, with the exchange held.
    fetch("/plaid_items", {
      method: "POST",
      headers: {
        Accept: "text/vnd.turbo-stream.html, text/html",
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
    })
      .then(async (response) => {
        if (response.redirected) {
          window.location.href = response.url;
          return;
        }

        // Checked first, because renderStreamMessage appends whatever it is given to
        // the page.
        const contentType = response.headers.get("Content-Type") || "";
        if (response.ok && contentType.includes("text/vnd.turbo-stream.html")) {
          Turbo.renderStreamMessage(await response.text());
          return;
        }

        this.showCreateFailed(`Unexpected response: ${response.status}`);
      })
      .catch((error) => this.showCreateFailed(error));
  };

  // Link has closed by now, so when the request fails outright -- the network, or a
  // server error the controller doesn't answer with a stream -- nothing else on the
  // page says so. Whether the connection was added is unknown, so the alert, rendered
  // by the server into a template, asks the user to check.
  showCreateFailed(error) {
    console.error("Failed to add the Plaid connection", error);

    const tray = document.getElementById("notification-tray");
    if (!tray || !this.hasCreateFailedTarget) return;

    tray.append(this.createFailedTarget.content.cloneNode(true));
  }

  handleExit = (err, metadata) => {
    // If there was an error during update mode, refresh the page to show
    // latest status. Guard `metadata` (Plaid can fire onExit with it
    // undefined when Link aborts very early) and gate the redirect on
    // `isUpdateValue` so first-time link failures don't bounce the user
    // away from whatever page they were on.
    if (
      err &&
      metadata &&
      metadata.status === "requires_credentials" &&
      this.isUpdateValue
    ) {
      window.location.href = "/accounts";
      return;
    }

    // Promote Plaid's own error payload to the console so a silent modal
    // close still leaves a breadcrumb (issue #1792). Plaid Link's own UI
    // is responsible for showing a message inside the modal when this
    // fires; backend link-token failures are handled server-side via the
    // PlaidItemsController rescue + flash.
    if (err?.error_code) {
      console.error(
        "Plaid Link exited with error",
        err.error_code,
        err.display_message || err.error_message
      );
    }
  };

  handleEvent = (eventName, metadata) => {
    // no-op
  };

  handleLoad = () => {
    // no-op
  };
}
