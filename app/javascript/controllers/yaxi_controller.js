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
    this.client = new RoutexClient({ url: new URL(this.baseUrlValue) });
    this.client.setRedirectUri(this.redirectUri());

    if (
      new URL(window.location.href).searchParams.get("yaxi_redirect") === "1"
    ) {
      this.resumeRedirect();
    }
  }

  async submitCredentials(event) {
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
      await this.invoke(state, {
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
      await this.invoke(state, { accounts: this.accountReferencesValue });
    } catch (error) {
      this.showError(error);
    }
  }

  async invoke(state, extra = {}) {
    this.pendingState = { ...state, extra };
    const credentials = this.hydrateCredentials(state.credentials);
    const session = state.session ? new Uint8Array(state.session) : undefined;
    let response;

    if (state.operation === "accounts") {
      response = await this.client.accounts({
        credentials,
        session,
        recurringConsents: true,
        ticket: state.ticket,
        ...extra,
      });
    } else if (state.operation === "balances") {
      response = await this.client.balances({
        credentials,
        session,
        recurringConsents: true,
        ticket: state.ticket,
        ...extra,
      });
    } else {
      response = await this.client.transactions({
        credentials,
        session,
        recurringConsents: true,
        ticket: state.ticket,
      });
    }

    await this.advance(response, this.pendingState);
  }

  async advance(response, state) {
    if (response instanceof Result) return this.handleResult(response, state);
    if (response instanceof Dialog) {
      this.clearBusy();
      this.pendingState = state;
      this.pendingDialog = response;
      window.dispatchEvent(new CustomEvent("yaxi-dialog:show", { detail: { response } }));
      return;
    }
    if (response instanceof Redirect || response instanceof RedirectHandle)
      return this.followRedirect(response, state);
    throw new Error(this.message("unsupported_response"));
  }

  async handleResult(response, state) {
    if (response.session) state.session = Array.from(response.session);
    if (response.connectionData)
      state.credentials.connectionData = Array.from(response.connectionData);

    if (state.stage === "connect") {
      storeCredentials(this.storageIdValue, this.secretBytes(), {
        credentials: state.credentials,
      });
      return this.submitResult({
        ticket_id: state.ticketId,
        result_jwt: response.jwt,
        connection_info: state.connectionInfo,
      });
    }

    if (state.stage === "refresh_balances") {
      state.balancesResultJwt = response.jwt;
      return this.startTransaction(state);
    }

    state.transactionResults.push({
      account_id: state.currentTransaction.account_id,
      ticket_id: state.currentTransaction.ticket_id,
      result_jwt: response.jwt,
    });
    state.transactionIndex += 1;
    return this.startTransaction(state);
  }

  async startTransaction(state) {
    storeCredentials(this.storageIdValue, this.secretBytes(), {
      credentials: state.credentials,
    });
    const next = state.transactionTickets[state.transactionIndex];
    if (!next) {
      return this.submitResult({
        balances_ticket_id: state.balancesTicketId,
        balances_result_jwt: state.balancesResultJwt,
        transaction_results: state.transactionResults,
      });
    }

    state.stage = "refresh_transactions";
    state.operation = "transactions";
    state.ticket = next.token;
    state.ticketId = next.ticket_id;
    state.currentTransaction = next;
    this.setBusy(
      this.message("refreshing_transactions")
        .replace("__CURRENT__", state.transactionIndex + 1)
        .replace("__TOTAL__", state.transactionTickets.length),
    );
    return this.invoke(state);
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
      await this.advance(response, state);
    } catch (error) {
      this.showError(error);
    }
  }

  async followRedirect(response, state) {
    const context = Array.from(response.context);
    storeCredentials(this.storageIdValue, this.secretBytes(), {
      credentials: state.credentials,
    });
    const { credentials, ...resumableState } = state;
    sessionStorage.setItem(
      this.redirectStorageKey(),
      JSON.stringify({ ...resumableState, redirectContext: context }),
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
    const serialized = sessionStorage.getItem(this.redirectStorageKey());
    if (!serialized)
      return this.showError(new Error(this.message("redirect_missing")));
    sessionStorage.removeItem(this.redirectStorageKey());

    try {
      const state = JSON.parse(serialized);
      const stored = loadCredentials(this.storageIdValue, this.secretBytes());
      if (!stored?.credentials)
        throw new Error(this.message("credentials_missing"));
      state.credentials = stored.credentials;
      this.setBusy(this.message("completing_authorization"));
      const response = await this.callContinuation(state.operation, "confirm", {
        ticket: state.ticket,
        context: new Uint8Array(state.redirectContext),
      });
      await this.advance(response, state);
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
      window.location.assign(payload.redirect_url);
    } catch (error) {
      this.showError(error);
    }
  }

  hydrateCredentials(credentials) {
    return {
      ...credentials,
      connectionData: credentials.connectionData
        ? new Uint8Array(credentials.connectionData)
        : undefined,
    };
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
    window.dispatchEvent(new CustomEvent("yaxi-status:busy", { detail: { value: message } }));
  }

  clearBusy() {
    window.dispatchEvent(new CustomEvent("yaxi-status:clear"));
  }

  showError(error) {
    this.clearBusy();
    window.dispatchEvent(new CustomEvent("yaxi-dialog:hide"));
    const displayedError = error.userMessage || this.message("request_failed");
    window.dispatchEvent(new CustomEvent("yaxi-status:error", {
      detail: { value: displayedError },
    }));
  }
}
