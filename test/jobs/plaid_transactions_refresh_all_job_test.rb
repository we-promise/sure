require "test_helper"

class PlaidTransactionsRefreshAllJobTest < ActiveJob::TestCase
  test "requests transaction refreshes for syncable Plaid items" do
    family = families(:dylan_family)

    PlaidItem.any_instance.expects(:request_transactions_refresh_later).once

    PlaidTransactionsRefreshAllJob.perform_now(family, source: "TestSync")
  end

  test "contains per-item refresh failures and records a sanitized diagnostic" do
    family = families(:dylan_family)

    PlaidItem.any_instance.stubs(:request_transactions_refresh_later).raises(RedisClient::Error, "Redis unavailable")

    assert_difference "DebugLogEntry.count", 1 do
      PlaidTransactionsRefreshAllJob.perform_now(family, source: "TestSync")
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "provider_sync", entry.category
    assert_equal "TestSync", entry.source
    assert_equal family, entry.family
    assert_equal "RedisClient::Error", entry.metadata["error_class"]
  end

  test "contains Plaid item query failures" do
    family = families(:dylan_family)
    family.stubs(:plaid_items).raises(ActiveRecord::ConnectionNotEstablished, "DB unavailable")

    assert_difference "DebugLogEntry.count", 1 do
      PlaidTransactionsRefreshAllJob.perform_now(family, source: "TestSync")
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "ActiveRecord::ConnectionNotEstablished", entry.metadata["error_class"]
  end
end
