import { Controller } from "@hotwired/stimulus";
import {
  AccountField,
  Dialog,
  Redirect,
  RedirectHandle,
  Result,
  RoutexClient,
  loadCredentials,
  storeCredentials,
} from "routex-client";
import {
  YaxiFlow,
  consumeYaxiRedirectState,
  persistYaxiRedirectState,
  yaxiErrorMessage,
} from "services/yaxi_flow";

export default class extends Controller {
  static values = {
    ticket: String,
    ticketId: String,
    baseUrl: String,
    submitUrl: String,
    storageId: String,
    storageSecret: String,
    balancesTicket: String,
    balancesTicketId: String,
    transactionTickets: Array,
    accountReferences: Array,
    messages: Object,
  };

  connect() {
    this.running = false;
    this.client = new RoutexClient({ url: new URL(this.baseUrlValue) });
    this.client.setRedirectUri(this.redirectUri());
    this.flow = new YaxiFlow({
      client: this.client,
      responseTypes: { Result, Dialog, Redirect, RedirectHandle },
      storeCredentials: (credentials) => this.storeCredentials(credentials),
      submitResult: (body) => this.submitResult(body),
      showDialog: (response, state) => this.showDialog(response, state),
      followRedirect: (response, state) => this.followRedirect(response, state),
      setBusy: (message) => this.setBusy(message),
      message: (key) => this.message(key),
    });

    if (
      new URL(window.location.href).searchParams.get("yaxi_redirect") === "1"
    ) {
      this.running = true;
      this.resumeRedirect();
    }
  }

  async submitCredentials(event) {
    if (this.running) return;
    this.running = true;

    const { credentials, connectionInfo } = event.detail;
    const state = {
      stage: "connect",
      operation: "accounts",
      ticket: this.ticketValue,
      ticketId: this.ticketIdValue,
      credentials,
      connectionInfo,
    };

    this.setBusy(this.message("connecting"));
    try {
      await this.flow.invoke(state, {
        fields: [
          AccountField.Iban,
          AccountField.Number,
          AccountField.Bic,
          AccountField.Currency,
          AccountField.Name,
          AccountField.DisplayName,
          AccountField.OwnerName,
          AccountField.ProductName,
          AccountField.Status,
          AccountField.Type,
        ],
      });
    } catch (error) {
      this.showError(error);
    }
  }

  async startRefresh() {
    if (this.running) return;
    this.running = true;

    try {
      const stored = loadCredentials(this.storageIdValue, this.secretBytes());
      if (!stored?.credentials) {
        this.showError(new Error(this.message("credentials_missing")));
        return;
      }

      const state = {
        stage: "refresh_balances",
        operation: "balances",
        ticket: this.balancesTicketValue,
        ticketId: this.balancesTicketIdValue,
        balancesTicketId: this.balancesTicketIdValue,
        credentials: stored.credentials,
        transactionTickets: this.transactionTicketsValue,
        transactionIndex: 0,
        transactionResults: [],
      };

      this.setBusy(this.message("refreshing_balances"));
      await this.flow.invoke(state, { accounts: this.accountReferencesValue });
    } catch (error) {
      this.showError(error);
    }
  }

  async respondToDialog(event) {
    await this.continueService("respond", event.detail.value);
  }

  async confirmDialog() {
    await this.continueService("confirm");
  }

  async continueService(kind, value) {
    this.setBusy(this.message("waiting"));
    try {
      const state = this.pendingState;
      const options = {
        ticket: state.ticket,
        context: this.pendingDialog.input.context,
      };
      if (kind === "respond") options.response = value;
      const response = await this.callContinuation(
        state.operation,
        kind,
        options,
      );
      await this.flow.advance(response, state);
    } catch (error) {
      this.showError(error);
    }
  }

  async followRedirect(response, state) {
    this.storeCredentials(state.credentials);
    persistYaxiRedirectState(
      sessionStorage,
      this.redirectStorageKey(),
      state,
      response.context,
    );
    const url =
      response instanceof RedirectHandle
        ? await this.client.registerRedirectUri({
            ticket: state.ticket,
            handle: response.handle,
            redirectUri: this.redirectUri(),
          })
        : response.url;
    window.location.assign(url.toString());
  }

  async resumeRedirect() {
    try {
      const state = consumeYaxiRedirectState(
        sessionStorage,
        this.redirectStorageKey(),
      );
      if (!state)
        return this.showError(new Error(this.message("redirect_missing")));

      const stored = loadCredentials(this.storageIdValue, this.secretBytes());
      if (!stored?.credentials)
        throw new Error(this.message("credentials_missing"));
      state.credentials = stored.credentials;
      this.setBusy(this.message("completing_authorization"));
      const response = await this.callContinuation(state.operation, "confirm", {
        ticket: state.ticket,
        context: new Uint8Array(state.redirectContext),
      });
      await this.flow.advance(response, state);
    } catch (error) {
      this.showError(error);
    }
  }

  callContinuation(operation, kind, options) {
    const suffix = operation.charAt(0).toUpperCase() + operation.slice(1);
    return this.client[`${kind}${suffix}`](options);
  }

  async submitResult(body) {
    this.setBusy(this.message("saving"));
    try {
      const response = await fetch(this.submitUrlValue, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')
            ?.content,
        },
        body: JSON.stringify(body),
      });
      const responseBody = await response.text();
      let payload = {};
      try {
        payload = responseBody ? JSON.parse(responseBody) : {};
      } catch {
        throw new Error(`${this.message("save_failed")} (${response.status})`);
      }
      if (!response.ok)
        throw new Error(payload.error || this.message("save_failed"));
      if (!payload.redirect_url) throw new Error(this.message("save_failed"));
      this.running = false;
      window.location.assign(payload.redirect_url);
    } catch (error) {
      this.showError(error);
    }
  }

  storeCredentials(credentials) {
    storeCredentials(this.storageIdValue, this.secretBytes(), { credentials });
  }

  showDialog(response, state) {
    this.clearBusy();
    this.pendingState = state;
    this.pendingDialog = response;
    window.dispatchEvent(
      new CustomEvent("yaxi-dialog:show", { detail: { response } }),
    );
  }

  secretBytes() {
    const binary = atob(this.storageSecretValue);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  }

  redirectUri() {
    const url = new URL(window.location.href);
    url.searchParams.set("yaxi_redirect", "1");
    return url.toString();
  }

  redirectStorageKey() {
    return `sure:yaxi:${this.storageIdValue}:redirect`;
  }

  message(key) {
    return this.messagesValue[key] || key;
  }

  setBusy(message) {
    window.dispatchEvent(
      new CustomEvent("yaxi-status:busy", { detail: { value: message } }),
    );
  }

  clearBusy() {
    window.dispatchEvent(new CustomEvent("yaxi-status:clear"));
  }

  showError(error) {
    this.running = false;
    this.clearBusy();
    window.dispatchEvent(new CustomEvent("yaxi-dialog:hide"));
    const displayedError = yaxiErrorMessage(
      error,
      this.message("request_failed"),
    );
    window.dispatchEvent(
      new CustomEvent("yaxi-status:error", {
        detail: { value: displayedError },
      }),
    );
  }
}
