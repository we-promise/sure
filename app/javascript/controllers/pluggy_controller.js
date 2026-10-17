import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="pluggy"
// Lazy-loads the Pluggy Connect widget from Pluggy's CDN. On success the
// widget returns the created itemId; unlike Plaid there is no public-token
// exchange — the id is usable directly with the developer credentials (see
// PluggyItem::Provider#item_id), so we POST it verbatim and let
// PluggyItemsController#create enqueue the initial sync.
export default class extends Controller {
  static values = {
    connectToken: String,
    isUpdate: { type: Boolean, default: false },
    // `itemId` is the Pluggy upstream item id used to authorize the connect
    // token for UPDATE mode (config.updateItem); `recordId` is the local
    // PluggyItem DB row id used to POST /pluggy_items/:id/sync on update
    // success. The member :sync route's params[:id] is the DB record id, NOT
    // the Pluggy item id, so these must be distinct values.
    itemId: String,
    recordId: String,
    // When true the widget opens automatically on connect() (the standalone
    // Pluggy connect page sets this). Defaults to false so the settings panel
    // never auto-opens a background widget behind the Sure drawer — the
    // "Open Pluggy Connect" button is the explicit trigger instead.
    autoOpen: { type: Boolean, default: false },
  };

  connect() {
    this._connectionToken = (this._connectionToken ?? 0) + 1;

    // Only auto-open on the standalone connect page (autoOpenValue=true). The
    // settings panel leaves this false so no background widget opens behind the
    // Sure drawer — the user clicks "Open Pluggy Connect" explicitly.
    if (!this.autoOpenValue) return;

    const connectionToken = this._connectionToken;
    this.open(connectionToken).catch((error) => {
      console.error("Failed to initialize Pluggy Connect widget", error);
    });
  }

  disconnect() {
    this._handler?.destroy?.();
    this._handler = null;
    this._connectionToken = (this._connectionToken ?? 0) + 1;
  }

  waitForPluggy() {
    if (typeof PluggyConnect !== "undefined") {
      return Promise.resolve();
    }

    return new Promise((resolve, reject) => {
      let pluggyScript = document.querySelector(
        'script[src*="pluggy-connect.js"]'
      );

      // Reject if the CDN request stalls without firing load or error
      const timeoutId = window.setTimeout(() => {
        if (pluggyScript) pluggyScript.dataset.pluggyState = "error";
        reject(new Error("Timed out loading Pluggy Connect script"));
      }, 10_000);

      // Remove previously failed script so we can retry with a fresh element
      if (pluggyScript?.dataset.pluggyState === "error") {
        pluggyScript.remove();
        pluggyScript = null;
      }

      if (!pluggyScript) {
        pluggyScript = document.createElement("script");
        pluggyScript.src =
          "https://cdn.pluggy.ai/pluggy-connect/v2.8.2/pluggy-connect.js";
        // SRI pins the CDN-served script to its v2.8.2 hash so a tampered or
        // compromised CDN can't swap the widget code; crossOrigin is required
        // for integrity enforcement and is safe because cdn.pluggy.ai serves
        // `Access-Control-Allow-Origin: *` (verified). Bump the hash whenever
        // the pinned version above changes — recompute with:
        //   curl -s <src> | openssl dgst -sha384 -binary | base64 -w0
        pluggyScript.integrity =
          "sha384-TiENJGtPLgAoIa1MVo8Euy1JSwDECMBKmbxMFz5b+nMo/A6DdIwvMk1JnYnkM2pv";
        pluggyScript.crossOrigin = "anonymous";
        pluggyScript.async = true;
        pluggyScript.dataset.pluggyState = "loading";
        document.head.appendChild(pluggyScript);
      }

      pluggyScript.addEventListener(
        "load",
        () => {
          window.clearTimeout(timeoutId);
          pluggyScript.dataset.pluggyState = "loaded";
          resolve();
        },
        { once: true }
      );
      pluggyScript.addEventListener(
        "error",
        () => {
          window.clearTimeout(timeoutId);
          pluggyScript.dataset.pluggyState = "error";
          reject(new Error("Failed to load Pluggy Connect script"));
        },
        { once: true }
      );

      // Re-check after attaching listeners in case the script loaded between
      // the initial typeof check and listener attachment (avoids a
      // permanently pending promise on retry flows).
      if (typeof PluggyConnect !== "undefined") {
        window.clearTimeout(timeoutId);
        resolve();
      }
    });
  }

  async open(connectionToken = this._connectionToken) {
    // Stimulus passes the DOM event as the first positional arg when this is
    // bound as `data-action="click->pluggy#open"` (see _pluggy_panel). The
    // `= this._connectionToken` default only applies when called with NO arg,
    // so a click would otherwise make `connectionToken` a PointerEvent and the
    // stale-token guard below (`token !== this._connectionToken`) would abort
    // EVERY click — the "Open Pluggy Connect does nothing" symptom. Coerce a
    // non-numeric arg (the click event) back to the current token so the guard
    // only aborts genuine mid-open reconnects, not clicks. Resolve into a local
    // rather than reassigning the parameter (biome noParameterAssign).
    const token = typeof connectionToken === "number" ? connectionToken : this._connectionToken;

    try {
      await this.waitForPluggy();
      if (token !== this._connectionToken) {
        return;
      }

      const config = {
        connectToken: this.connectTokenValue,
        onSuccess: this.handleSuccess,
        onError: this.handleError,
      };

      // In update mode, authorize the connect token against the existing item
      // so Pluggy Connect triggers an update (and prompts for credentials if
      // they've gone stale) instead of creating a new connection.
      if (this.isUpdateValue && this.itemIdValue) {
        config.updateItem = this.itemIdValue;
      }

      this._handler = new PluggyConnect(config);
      // Await zoid's render so a render rejection (invalid/expired connect
      // token, prop-adaptation failure, missing render container) is caught
      // here and surfaced via showError(...) instead of becoming a silent,
      // unhandled promise rejection — which is why the button appeared to "do
      // nothing" with no visible feedback. init() returns
      // componentInstance.render(container).catch(...) (see PluggyConnect SDK),
      // so awaiting it threads the rejection into this try/catch.
      await this._handler.init();
    } catch (error) {
      // Without this catch a waitForPluggy() rejection (CDN blocked/timeout)
      // or a PluggyConnect() throw becomes an unhandled promise rejection —
      // the button visibly does nothing. Surface it so the failure is
      // actionable instead of silent.
      console.error("[pluggy] open() failed:", error);
      this.showError(error);
    }
  }

  handleSuccess = (itemData) => {
    // Pluggy Connect passes `{ item: { id } }` on success (see Pluggy widget
    // docs). `item.id` is the created item id, usable directly with the
    // developer credentials — no public-token exchange is needed.
    const itemId = itemData?.item?.id;

    if (this.isUpdateValue) {
      // Trigger a sync to verify the connection and refresh status. The member
      // :sync route is keyed by the PluggyItem DB record id (recordIdValue),
      // NOT the Pluggy upstream item id (itemIdValue, which authorizes
      // config.updateItem). Using itemIdValue here would 404 the sync after a
      // successful re-auth.
      // `meta[name="csrf-token"]?.content` (optional chaining) — the bare
      // `[name="csrf-token"]` selector throws a TypeError if the meta tag is
      // absent (a layout without csrf_meta_tags, or a Turbo-stream render
      // context), which kills this success callback synchronously before
      // fetch fires. Matches the safe form used across most other controllers.
      fetch(`/pluggy_items/${this.recordIdValue}/sync`, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
        },
      }).then((response) => {
        // Only navigate on a successful enqueue — #sync returns 422 with a
        // JSON error when the item has no pluggy_item_id, and jumping to
        // /accounts on that would mask a failed re-auth as a success.
        if (response.ok) {
          // Refresh the page to show the updated status.
          window.location.href = "/accounts";
        } else {
          this.showError(new Error(`Sync request failed (${response.status})`));
        }
      }).catch((error) => {
        this.showError(error);
      });
      return;
    }

    // Store the widget-returned itemId verbatim. When the widget was opened
    // from an existing credential-only PluggyItem (this.recordIdValue present
    // — issued by PluggyItemsController#update's connect-token path), PATCH
    // that record so the itemId binds to the credentialed row instead of
    // POSTing a second, orphan PluggyItem. The controller's update path
    // preserves client_secret when the field is blank, enqueues a sync once
    // pluggy_item_id is present, and re-renders the panel. Fall back to the
    // collection POST only when no record id is wired (standalone new page).
    const saveUrl = this.recordIdValue
      ? `/pluggy_items/${this.recordIdValue}`
      : "/pluggy_items";
    const saveMethod = this.recordIdValue ? "PATCH" : "POST";
    fetch(saveUrl, {
      method: saveMethod,
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      },
      body: JSON.stringify({
        pluggy_item: {
          pluggy_item_id: itemId,
        },
      }),
    }).then((response) => {
      if (response.redirected) {
        window.location.href = response.url;
      } else if (!response.ok) {
        // A non-redirect error (e.g. 422 validation) means the connection
        // record wasn't saved — surface it instead of leaving the user on a
        // stale page with no feedback that the widget success went nowhere.
        this.showError(new Error(`Save request failed (${response.status})`));
      }
    }).catch((error) => {
      this.showError(error);
    });
  };

  handleError = (error) => {
    console.error("Pluggy Connect widget error", error);
    this.showError(error);
  };

  // Surface a Pluggy Connect failure as a visible banner inside this
  // controller's element so a click that "does nothing" is no longer silent —
  // the user sees why (CDN timeout, invalid token, widget error) and the
  // detail is also logged to the browser console.
  showError(error) {
    const message = error?.message || String(error) || "Unknown error";
    console.error("Pluggy Connect failed to open:", message);

    const previous = this.element.querySelector("[data-pluggy-error]");
    if (previous) previous.remove();

    const banner = document.createElement("div");
    banner.setAttribute("data-pluggy-error", "");
    banner.className =
      "mt-3 p-3 rounded-lg bg-destructive/10 text-destructive text-sm break-words";
    banner.textContent = `Could not open Pluggy Connect: ${message}`;
    this.element.appendChild(banner);
  }
}
