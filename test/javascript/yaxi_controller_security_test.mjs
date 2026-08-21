import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const serviceSource = readFileSync(
  new URL("../../app/javascript/services/yaxi_flow.js", import.meta.url),
  "utf8",
);
const serviceUrl = `data:text/javascript;base64,${Buffer.from(serviceSource).toString("base64")}`;
const {
  YaxiFlow,
  consumeYaxiRedirectState,
  persistYaxiRedirectState,
  yaxiErrorMessage,
} = await import(serviceUrl);

class MemoryStorage {
  constructor() {
    this.values = new Map();
    this.operations = [];
  }

  getItem(key) {
    this.operations.push(["get", key]);
    return this.values.get(key) ?? null;
  }

  setItem(key, value) {
    this.operations.push(["set", key, value]);
    this.values.set(key, value);
  }

  removeItem(key) {
    this.operations.push(["remove", key]);
    this.values.delete(key);
  }
}

class Result {
  constructor({ jwt, session, connectionData } = {}) {
    this.jwt = jwt;
    this.session = session;
    this.connectionData = connectionData;
  }
}

const responseTypes = {
  Result,
  Dialog: class Dialog {},
  Redirect: class Redirect {},
  RedirectHandle: class RedirectHandle {},
};

function buildFlow(overrides = {}) {
  return new YaxiFlow({
    client: {},
    responseTypes,
    storeCredentials: () => {},
    submitResult: () => {},
    showDialog: () => {},
    followRedirect: () => {},
    setBusy: () => {},
    message: (key) => key,
    ...overrides,
  });
}

describe("YAXI browser state", () => {
  it("stores redirect state without plaintext credentials", () => {
    const storage = new MemoryStorage();
    const state = {
      stage: "refresh_transactions",
      balancesTicketId: "balances-ticket",
      credentials: { userId: "alice", password: "secret-password" },
      transactionResults: [],
    };

    persistYaxiRedirectState(storage, "redirect", state, new Uint8Array([1, 2, 3]));

    const serialized = storage.getItem("redirect");
    assert.doesNotMatch(serialized, /alice|secret-password|credentials/);
    assert.equal(JSON.parse(serialized).balancesTicketId, "balances-ticket");
    assert.deepEqual(JSON.parse(serialized).redirectContext, [1, 2, 3]);
  });

  it("deletes redirect state before returning it for resume", () => {
    const storage = new MemoryStorage();
    storage.setItem("redirect", JSON.stringify({ stage: "connect" }));

    const state = consumeYaxiRedirectState(storage, "redirect");

    assert.deepEqual(state, { stage: "connect" });
    assert.deepEqual(storage.operations.slice(-2), [
      ["get", "redirect"],
      ["remove", "redirect"],
    ]);
    assert.equal(storage.getItem("redirect"), null);
  });

  it("routes credentials through the encrypted storage helper", async () => {
    const stored = [];
    const submitted = [];
    const credentials = { userId: "alice", password: "secret-password" };
    const flow = buildFlow({
      storeCredentials: (value) => stored.push(value),
      submitResult: (value) => submitted.push(value),
    });

    await flow.advance(new Result({ jwt: "signed-result" }), {
      stage: "connect",
      ticketId: "accounts-ticket",
      credentials,
      connectionInfo: { id: "bank-1" },
    });

    assert.deepEqual(stored, [credentials]);
    assert.deepEqual(submitted, [
      {
        ticket_id: "accounts-ticket",
        result_jwt: "signed-result",
        connection_info: { id: "bank-1" },
      },
    ]);
  });

  it("retains the balances ticket while aggregating transaction results", async () => {
    const submitted = [];
    const flow = buildFlow({ submitResult: (value) => submitted.push(value) });
    const state = {
      stage: "refresh_transactions",
      balancesTicketId: "balances-ticket",
      balancesResultJwt: "balances-result",
      credentials: {},
      currentTransaction: { account_id: "account-1", ticket_id: "transaction-ticket" },
      transactionTickets: [],
      transactionIndex: 0,
      transactionResults: [],
    };

    await flow.advance(new Result({ jwt: "transaction-result" }), state);

    assert.deepEqual(submitted, [
      {
        balances_ticket_id: "balances-ticket",
        balances_result_jwt: "balances-result",
        transaction_results: [
          {
            account_id: "account-1",
            ticket_id: "transaction-ticket",
            result_jwt: "transaction-result",
          },
        ],
      },
    ]);
  });

  it("shows only explicit user-safe errors", () => {
    assert.equal(
      yaxiErrorMessage({ userMessage: "Try again" }, "Request failed"),
      "Try again",
    );
    assert.equal(
      yaxiErrorMessage(new Error("internal provider detail"), "Request failed"),
      "Request failed",
    );
  });
});
