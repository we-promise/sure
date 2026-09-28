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
