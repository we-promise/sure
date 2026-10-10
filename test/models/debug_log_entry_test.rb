require "test_helper"

class DebugLogEntryTest < ActiveSupport::TestCase
  test "capture infers provider key and family from account" do
    entry = DebugLogEntry.capture(
      category: "provider_sync",
      level: "warn",
      message: "Provider event",
      source: "Provider::Test",
      account: accounts(:depository),
      provider: :twelve_data,
      metadata: { test: true }
    )

    assert entry.persisted?
    assert_equal "twelve_data", entry.provider_key
    assert_equal accounts(:depository), entry.account
    assert_equal accounts(:depository).family, entry.family
  end

  test "capture redacts sensitive metadata keys at the top level" do
    entry = DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "warn",
      message: "Provider event",
      source: "Provider::Test",
      metadata: {
        balance: "1234.56",
        account_amount: "99.00",
        address: "0xabc123",
        uid: "provider-uid-1",
        api_account_id: "acct-1",
        body: "raw response body",
        isin_qty: "10",
        status: "ok"
      }
    )

    assert_equal "[REDACTED]", entry.metadata["balance"]
    assert_equal "[REDACTED]", entry.metadata["account_amount"]
    assert_equal "[REDACTED]", entry.metadata["address"]
    assert_equal "[REDACTED]", entry.metadata["uid"]
    assert_equal "[REDACTED]", entry.metadata["api_account_id"]
    assert_equal "[REDACTED]", entry.metadata["body"]
    assert_equal "[REDACTED]", entry.metadata["isin_qty"]
    assert_equal "ok", entry.metadata["status"]
  end

  test "capture redacts credential-shaped metadata keys at any depth" do
    entry = DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "warn",
      message: "Provider event",
      source: "Provider::Test",
      metadata: {
        api_key: "sk-live-123",
        password: "hunter2",
        authorization: "Bearer abc",
        request: {
          headers: [ { access_token: "tok-1" }, { refresh_token: "tok-2" } ],
          client_secret: "shh"
        },
        status: "ok"
      }
    )

    assert_equal "[REDACTED]", entry.metadata["api_key"]
    assert_equal "[REDACTED]", entry.metadata["password"]
    assert_equal "[REDACTED]", entry.metadata["authorization"]
    assert_equal "[REDACTED]", entry.metadata["request"]["headers"][0]["access_token"]
    assert_equal "[REDACTED]", entry.metadata["request"]["headers"][1]["refresh_token"]
    assert_equal "[REDACTED]", entry.metadata["request"]["client_secret"]
    assert_equal "ok", entry.metadata["status"]
  end

  test "capture redacts personal-identifier keys at any depth" do
    entry = DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "warn",
      message: "Provider event",
      source: "Provider::Test",
      metadata: {
        # Deliberately not IBAN-shaped: redaction keys off the name, and a
        # realistic value would trip the CI secret scanner on this very diff.
        iban: "an-account-identifier",
        email: "person@example.com",
        details: { account_number: "12345678" },
        status: "ok"
      }
    )

    assert_equal "[REDACTED]", entry.metadata["iban"]
    assert_equal "[REDACTED]", entry.metadata["email"]
    assert_equal "[REDACTED]", entry.metadata["details"]["account_number"]
    assert_equal "ok", entry.metadata["status"]
  end

  test "capture redacts credential shapes embedded in string values" do
    entry = DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "warn",
      message: "Provider event",
      source: "Provider::Test",
      metadata: {
        error_message: "401 Unauthorized for header Authorization: Bearer sk-live-secret-123",
        response_fragment: 'server said {"access_token":"tok-abc","scope":"read"}',
        unquoted_fragment: 'rejected {"amount":42.5,"password":null,"note":"x"}',
        compound_fragment: 'got {"body":{"note":"raw response"},"status":200}',
        nested: [ { note: "retry with Basic dXNlcjpwYXNz later" } ],
        harmless: "connection timed out"
      }
    )

    assert_equal "401 Unauthorized for header Authorization: [REDACTED]", entry.metadata["error_message"]
    assert_equal 'server said {[REDACTED],"scope":"read"}', entry.metadata["response_fragment"]
    assert_equal 'rejected {[REDACTED],[REDACTED],"note":"x"}', entry.metadata["unquoted_fragment"]
    assert_equal 'got {[REDACTED],"status":200}', entry.metadata["compound_fragment"]
    assert_equal "retry with [REDACTED] later", entry.metadata["nested"][0]["note"]
    assert_equal "connection timed out", entry.metadata["harmless"]
  end

  test "capture redacts sensitive metadata keys inside nested hashes and arrays" do
    entry = DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "warn",
      message: "Provider event",
      source: "Provider::Test",
      metadata: {
        errors: [
          { transaction_id: "tx_1", error: "failed" },
          { transaction_id: "tx_2", balance: "500.00" }
        ],
        details: { nested: { amount: "42.00" } }
      }
    )

    assert_equal "tx_1", entry.metadata["errors"][0]["transaction_id"]
    assert_equal "failed", entry.metadata["errors"][0]["error"]
    assert_equal "[REDACTED]", entry.metadata["errors"][1]["balance"]
    assert_equal "[REDACTED]", entry.metadata["details"]["nested"]["amount"]
  end

  test "capture walks monetary lists and hashes but redacts every figure inside" do
    entry = DebugLogEntry.capture(
      category: "provider_sync",
      level: "info",
      message: "Provider event",
      source: "Provider::Test",
      metadata: {
        balance_type: "CLBD",
        amount_in_account_currency: "1234.56",
        other_balances: [
          { currency: "USD", balance_type: "CLBD", amount: "15.50", note: "15.50 USD", owner: { iban: "DE00" } },
          "42.00"
        ],
        balance_detail: { amount: { value: "5.00", currency: "USD" } },
        balances: { "EUR" => "100.00" },
        address_balances: [ { currency: "BTC" } ]
      }
    )

    assert_equal "[REDACTED]", entry.metadata["balance_type"]
    assert_equal "[REDACTED]", entry.metadata["amount_in_account_currency"]
    assert_equal(
      [
        { "currency" => "USD", "balance_type" => "CLBD", "amount" => "[REDACTED]", "note" => "[REDACTED]", "owner" => { "iban" => "[REDACTED]" } },
        "[REDACTED]"
      ],
      entry.metadata["other_balances"]
    )
    assert_equal({ "amount" => { "value" => "[REDACTED]", "currency" => "USD" } }, entry.metadata["balance_detail"])
    assert_equal "[REDACTED]", entry.metadata["balances"]
    assert_equal "[REDACTED]", entry.metadata["address_balances"]
  end

  test "capture does not redact unrelated keys that merely resemble sensitive ones" do
    entry = DebugLogEntry.capture(
      category: "provider_sync",
      level: "info",
      message: "Provider event",
      source: "Provider::Test",
      metadata: { monobank_account_id: "acct-1", enable_banking_item_id: "item-1" }
    )

    assert_equal "acct-1", entry.metadata["monobank_account_id"]
    assert_equal "item-1", entry.metadata["enable_banking_item_id"]
  end
end
