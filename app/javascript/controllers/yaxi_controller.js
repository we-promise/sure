import { Controller } from "@hotwired/stimulus";
import {
  AccountField,
  Confirmation,
  Dialog,
  Field,
  Redirect,
  RedirectHandle,
  Result,
  RoutexClient,
  SecrecyLevel,
  Selection,
  loadCredentials,
  storeCredentials,
} from "routex-client";

export default class extends Controller {
  static targets = [
    "searchSection",
    "searchInput",
    "results",
    "credentialsSection",
    "bankName",
    "advice",
    "userIdGroup",
    "userIdLabel",
    "userIdInput",
    "passwordGroup",
    "passwordLabel",
    "passwordInput",
    "refreshSection",
    "progress",
    "progressText",
    "error",
    "errorText",
    "dialog",
    "dialogMessage",
    "dialogImage",
    "dialogOptions",
    "dialogFieldGroup",
    "dialogField",
    "dialogContinue",
  ];

  static values = {
    mode: String,
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

  async search(event) {
    event.preventDefault();
    const query = this.searchInputTarget.value.trim();
    if (!query) return;

    this.setBusy(this.message("searching"));
    try {
      const filters = query.split(/\s+/).map((term) => ({ term }));
      const results = await this.client.search({
        ticket: this.ticketValue,
        filters,
        ibanDetection: true,
        limit: 20,
      });
      this.renderBanks(results);
      this.clearBusy();
    } catch (error) {
      this.showError(error);
    }
  }

  renderBanks(banks) {
    this.resultsTarget.replaceChildren();
    if (banks.length === 0) {
      const empty = document.createElement("p");
      empty.className = "text-sm text-secondary";
      empty.textContent = this.message("no_bank");
      this.resultsTarget.append(empty);
      return;
    }

    for (const bank of banks) {
      const button = document.createElement("button");
      button.type = "button";
      button.className =
        "w-full rounded-lg border border-primary p-3 text-left text-sm text-primary hover:bg-surface-hover";
      button.textContent = bank.displayName;
      button.addEventListener("click", () => this.selectBank(bank));
      this.resultsTarget.append(button);
    }
  }

  async selectBank(bank) {
    this.selectedBank = bank;
    this.bankNameTarget.textContent = bank.displayName;
    this.adviceTarget.textContent = bank.advice || "";

    const credentials = bank.credentials || {};
    const credentialModels = Array.isArray(credentials)
      ? credentials.map((value) => value.toString().toLowerCase())
      : Object.entries(credentials)
          .filter(([, enabled]) => enabled)
          .map(([key]) => key.toLowerCase());
    const needsUserId =
      credentialModels.includes("full") ||
      credentialModels.includes("userid") ||
      credentialModels.includes("user_id");
    const needsPassword = credentialModels.includes("full");
    this.userIdGroupTarget.classList.toggle("hidden", !needsUserId);
    this.passwordGroupTarget.classList.toggle("hidden", !needsPassword);
    this.userIdLabelTarget.textContent = bank.userId || this.message("user_id");
    this.passwordLabelTarget.textContent =
      bank.password || this.message("password");
    this.credentialsSectionTarget.classList.remove("hidden");
    this.credentialsSectionTarget.scrollIntoView({
      behavior: "smooth",
      block: "start",
    });
  }

  async submitCredentials(event) {
    event.preventDefault();
    if (!this.selectedBank) return;

    const credentials = { connectionId: this.selectedBank.id };
    if (!this.userIdGroupTarget.classList.contains("hidden"))
      credentials.userId = this.userIdInputTarget.value;
    if (!this.passwordGroupTarget.classList.contains("hidden"))
      credentials.password = this.passwordInputTarget.value;

    const state = {
      stage: "connect",
      operation: "accounts",
      ticket: this.ticketValue,
      ticketId: this.ticketIdValue,
      credentials,
      connectionInfo: this.selectedBank,
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
      credentials: stored.credentials,
      transactionTickets: this.transactionTicketsValue,
      transactionIndex: 0,
      transactionResults: [],
    };

    this.setBusy(this.message("refreshing_balances"));
    try {
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
    if (response instanceof Dialog) return this.showDialog(response, state);
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
        balances_ticket_id: this.balancesTicketIdValue,
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

  showDialog(response, state) {
    this.clearBusy();
    this.pendingState = state;
    this.pendingDialog = response;
    this.dialogTarget.classList.remove("hidden");
    this.dialogMessageTarget.textContent =
      response.message || this.message("confirm_request");
    this.dialogOptionsTarget.replaceChildren();
    this.dialogFieldGroupTarget.classList.add("hidden");
    this.dialogContinueTarget.classList.remove("hidden");

    if (response.image) this.showDialogImage(response.image);
    else this.dialogImageTarget.classList.add("hidden");

    if (response.input instanceof Selection) {
      this.dialogContinueTarget.classList.add("hidden");
      for (const option of response.input.options) {
        const button = document.createElement("button");
        button.type = "button";
        button.className =
          "w-full rounded-lg border border-primary p-3 text-left text-sm text-primary hover:bg-surface-hover";
        button.textContent = option.explanation
          ? `${option.label} — ${option.explanation}`
          : option.label;
        button.addEventListener("click", () =>
          this.respondToDialog(option.key),
        );
        this.dialogOptionsTarget.append(button);
      }
    } else if (response.input instanceof Field) {
      this.dialogFieldGroupTarget.classList.remove("hidden");
      this.dialogFieldTarget.value = "";
      this.dialogFieldTarget.type =
        response.input.secrecyLevel === SecrecyLevel.Password
          ? "password"
          : "text";
      if (response.input.minLength)
        this.dialogFieldTarget.minLength = response.input.minLength;
      if (response.input.maxLength)
        this.dialogFieldTarget.maxLength = response.input.maxLength;
      this.dialogFieldTarget.focus();
    } else if (
      response.input instanceof Confirmation &&
      response.input.pollingDelaySecs
    ) {
      this.dialogContinueTarget.classList.add("hidden");
      window.setTimeout(
        () => this.confirmDialog(),
        response.input.pollingDelaySecs * 1000,
      );
    }
  }

  continueDialog() {
    if (this.pendingDialog.input instanceof Field)
      return this.respondToDialog(this.dialogFieldTarget.value);
    return this.confirmDialog();
  }

  async respondToDialog(value) {
    await this.continueService("respond", value);
  }

  async confirmDialog() {
    await this.continueService("confirm");
  }

  async continueService(kind, value) {
    this.dialogTarget.classList.add("hidden");
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
    sessionStorage.setItem(
      this.redirectStorageKey(),
      JSON.stringify({ ...state, redirectContext: context }),
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

  showDialogImage(image) {
    if (this.dialogImageUrl) URL.revokeObjectURL(this.dialogImageUrl);
    this.dialogImageUrl = URL.createObjectURL(
      new Blob([image.data], { type: image.mimeType }),
    );
    this.dialogImageTarget.src = this.dialogImageUrl;
    this.dialogImageTarget.classList.remove("hidden");
  }

  setBusy(message) {
    this.errorTarget.classList.add("hidden");
    this.progressTextTarget.textContent = message;
    this.progressTarget.classList.remove("hidden");
  }

  clearBusy() {
    this.progressTarget.classList.add("hidden");
  }

  showError(error) {
    this.clearBusy();
    this.dialogTarget.classList.add("hidden");
    this.errorTextTarget.textContent =
      error.userMessage || error.message || this.message("request_failed");
    this.errorTarget.classList.remove("hidden");
  }
}
