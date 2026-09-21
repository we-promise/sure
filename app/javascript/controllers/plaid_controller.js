import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="plaid"
export default class extends Controller {
  static values = {
    linkToken: String,
    region: { type: String, default: "us" },
    isUpdate: { type: Boolean, default: false },
    itemId: String,
    accountableType: String,
    connectedInstitutionIds: Array,
    connectedInstitutionNames: Array,
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
    // Our own forced exit on a duplicate institution — the warning dialog is taking
    // over the modal frame. `err` is null for a forced exit, so the branches below
    // happen to be inert today, but that is accidental: this guard keeps a later
    // change to them from redirecting out from under the dialog.
    if (this._duplicateHandled) return;

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

  // Plaid documents SELECT_INSTITUTION as a stable event, fired once the user picks
  // an institution and before they authenticate. That is the only point where a
  // duplicate connection can still be prevented: Plaid creates the Item when Link
  // completes and the public token is issued, not when we exchange it, so a
  // server-side check in `create` would already be too late.
  handleEvent = (eventName, metadata) => {
    if (eventName !== "SELECT_INSTITUTION") return;

    // Update mode reconnects a known item, which is by definition its own duplicate
    // (Plaid may even auto-select the saved institution). Without this guard,
    // "Reconnect" and "Add accounts" — the two flows a user reaches when a connection
    // is already broken — would warn every time.
    if (this.isUpdateValue) return;

    // SELECT_INSTITUTION fires again when the user backs out and picks another bank,
    // so a one-shot flag keeps a second fire from double-navigating.
    if (this._duplicateHandled) return;

    // onEvent metadata is flat: institution_id sits at the top level, unlike the
    // nested institution object that onSuccess reports. Both fields are nullable.
    const institutionId = metadata?.institution_id;
    const institutionName = metadata?.institution_name;

    if (!this.isDuplicateInstitution(institutionId, institutionName)) return;

    this._duplicateHandled = true;

    // Close Link first. Navigating first risks disconnect() calling destroy() with no
    // preceding exit(), leaving Plaid's own DOM behind.
    this._handler?.exit({ force: true });

    Turbo.visit(this.duplicateWarningUrl(institutionId, institutionName), {
      frame: "modal",
    });
  };

  isDuplicateInstitution(institutionId, institutionName) {
    if (
      institutionId &&
      this.connectedInstitutionIdsValue.includes(institutionId)
    ) {
      return true;
    }

    // Fallback for connections whose first sync never landed, so no institution_id was
    // ever stored. The server sends these names already trimmed and lowercased.
    const name = institutionName?.trim().toLowerCase();

    return Boolean(name) && this.connectedInstitutionNamesValue.includes(name);
  }

  duplicateWarningUrl(institutionId, institutionName) {
    const url = new URL(
      "/plaid_items/duplicate_warning",
      window.location.origin,
    );

    url.searchParams.set("region", this.regionValue);
    if (institutionId) url.searchParams.set("institution_id", institutionId);
    if (institutionName)
      url.searchParams.set("institution_name", institutionName);
    if (this.accountableTypeValue)
      url.searchParams.set("accountable_type", this.accountableTypeValue);

    return url.toString();
  }

  handleLoad = () => {
    // no-op
  };
}
