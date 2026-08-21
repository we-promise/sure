export class YaxiFlow {
  constructor({
    client,
    responseTypes,
    storeCredentials,
    submitResult,
    showDialog,
    followRedirect,
    setBusy,
    message,
  }) {
    this.client = client;
    this.responseTypes = responseTypes;
    this.storeCredentials = storeCredentials;
    this.submitResult = submitResult;
    this.showDialog = showDialog;
    this.followRedirect = followRedirect;
    this.setBusy = setBusy;
    this.message = message;
  }

  async invoke(state, extra = {}) {
    const pendingState = { ...state, extra };
    const credentials = this.#hydrateCredentials(state.credentials);
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

    await this.advance(response, pendingState);
  }

  async advance(response, state) {
    const { Result, Dialog, Redirect, RedirectHandle } = this.responseTypes;

    if (response instanceof Result) return this.handleResult(response, state);
    if (response instanceof Dialog) return this.showDialog(response, state);
    if (response instanceof Redirect || response instanceof RedirectHandle) {
      return this.followRedirect(response, state);
    }
    throw new Error(this.message("unsupported_response"));
  }

  async handleResult(response, state) {
    if (response.session) state.session = Array.from(response.session);
    if (response.connectionData) {
      state.credentials.connectionData = Array.from(response.connectionData);
    }

    if (state.stage === "connect") {
      this.storeCredentials(state.credentials);
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
    this.storeCredentials(state.credentials);
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

  #hydrateCredentials(credentials) {
    return {
      ...credentials,
      connectionData: credentials.connectionData
        ? new Uint8Array(credentials.connectionData)
        : undefined,
    };
  }
}

export function persistYaxiRedirectState(storage, key, state, context) {
  const { credentials: _credentials, ...resumableState } = state;
  storage.setItem(
    key,
    JSON.stringify({ ...resumableState, redirectContext: Array.from(context) }),
  );
}

export function consumeYaxiRedirectState(storage, key) {
  const serialized = storage.getItem(key);
  if (!serialized) return null;

  storage.removeItem(key);
  return JSON.parse(serialized);
}

export function yaxiErrorMessage(error, fallback) {
  return error?.userMessage || fallback;
}
