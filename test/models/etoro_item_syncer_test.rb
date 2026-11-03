require "test_helper"

class EtoroItemSyncerTest < ActiveSupport::TestCase
  setup do
    @item = etoro_items(:configured_item)
    @syncer = EtoroItem::Syncer.new(@item)
  end

  test "a missing key fails the sync and asks for new keys" do
    @item.update!(user_key: nil)

    error = assert_raises(Provider::Etoro::ConfigurationError) { @syncer.perform_sync(@item.syncs.create!) }

    assert_equal "eToro API key is missing.", error.message
    assert @item.reload.requires_update?
  end

  test "rejected keys fail the sync and ask for new keys" do
    sync = @item.syncs.create!
    Provider::Etoro.any_instance.expects(:fetch_balances)
      .raises(Provider::Etoro::AuthenticationError, "eToro authentication failed (401).")

    assert_raises(Provider::Etoro::AuthenticationError) { @syncer.perform_sync(sync) }

    assert @item.reload.requires_update?
    assert_equal "auth_error", sync.reload.sync_stats.dig("errors", 0, "category")
  end

  # The user replaced the keys while the sync ran with the old ones.
  test "keys replaced during a sync the old keys fail stay in good standing" do
    sync = @item.syncs.create!
    Provider::Etoro.any_instance.expects(:fetch_balances)
      .with { |*| EtoroItem.find(@item.id).update!(api_key: "rotated_public_key", status: :good) }
      .raises(Provider::Etoro::AuthenticationError, "eToro authentication failed (401).")

    assert_raises(Provider::Etoro::AuthenticationError) { @syncer.perform_sync(sync) }

    assert @item.reload.good?
    assert_equal "rotated_public_key", @item.api_key
    assert_equal "auth_error", sync.reload.sync_stats.dig("errors", 0, "category")
  end

  test "a sync that gets through puts the connection back in good standing" do
    @item.update!(status: :requires_update)
    Provider::Etoro.any_instance.stubs(:fetch_balances).returns({
      "balances" => [ { "accountId" => "etoro_trading_1", "accountType" => "Trading", "currency" => "USD", "balance" => 100 } ]
    })
    Provider::Etoro.any_instance.stubs(:fetch_portfolio).returns({ "clientPortfolio" => { "positions" => [] } })
    Provider::Etoro.any_instance.stubs(:fetch_trade_history_page).returns([])
    Provider::Etoro.any_instance.stubs(:fetch_balance_history).returns({ "snapshots" => [] })

    @syncer.perform_sync(@item.syncs.create!)

    assert @item.reload.good?
  end

  test "flags the account for setup while it is unlinked" do
    EtoroItem::Importer.any_instance.expects(:import).returns({ success: true })
    EtoroItem.any_instance.expects(:process_accounts).never

    @syncer.perform_sync(@item.syncs.create!)

    assert @item.reload.pending_account_setup?
  end

  test "processes the linked account and counts the holdings it imported" do
    @item.update!(pending_account_setup: true)
    etoro_accounts(:main_account).ensure_account_provider!(accounts(:investment))
    EtoroItem::Importer.any_instance.expects(:import).returns({ success: true, partial_failures: [] })
    EtoroItem.any_instance.expects(:process_accounts).returns([
      { etoro_account_id: etoro_accounts(:main_account).id, success: true, result: { holdings: 2, failed_records: 0 } }
    ])
    sync = @item.syncs.create!

    @syncer.perform_sync(sync)

    assert_not @item.reload.pending_account_setup?
    stats = sync.reload.sync_stats
    assert_equal 2, stats["holdings_processed"]
    assert_equal 0, stats["total_errors"]
    assert_not stats.key?("tx_seen"), "eToro imports no transactions"
  end

  test "reports failed processing and history eToro did not send" do
    etoro_accounts(:main_account).ensure_account_provider!(accounts(:investment))
    EtoroItem::Importer.any_instance.expects(:import).returns({
      success: true,
      partial_failures: [ { what: :balance_history, message: "eToro API unavailable (status 502)" } ]
    })
    EtoroItem.any_instance.expects(:process_accounts).returns([
      { etoro_account_id: etoro_accounts(:main_account).id, success: false, error: "Failed to set the current balance" }
    ])
    sync = @item.syncs.create!

    @syncer.perform_sync(sync)

    stats = sync.reload.sync_stats
    assert_equal 2, stats["total_errors"]
    assert_equal [
      { "name" => I18n.t("etoro_items.sync.partial_failures.balance_history"), "message" => "eToro API unavailable (status 502)", "category" => "partial_fetch" },
      { "message" => "Failed to set the current balance", "category" => "sync_error" }
    ], stats["errors"]
  end

  test "reports records that failed to import" do
    etoro_accounts(:main_account).ensure_account_provider!(accounts(:investment))
    EtoroItem::Importer.any_instance.expects(:import).returns({ success: true })
    EtoroItem.any_instance.expects(:process_accounts).returns([
      { etoro_account_id: etoro_accounts(:main_account).id, success: true, result: { holdings: 1, failed_records: 3 } }
    ])
    sync = @item.syncs.create!

    @syncer.perform_sync(sync)

    assert_equal [ I18n.t("etoro_items.sync.errors.records_failed", count: 3) ], sync.reload.sync_stats["errors"].map { |error| error["message"] }
  end

  test "reports eToro's rate limit" do
    rate_limited_at = Time.current.change(usec: 0)
    EtoroItem::Importer.any_instance.expects(:import).returns({
      success: true,
      partial_failures: [ { what: :trade_history, message: "eToro rate limit exceeded." } ],
      rate_limited_at: rate_limited_at
    })
    sync = @item.syncs.create!

    @syncer.perform_sync(sync)

    stats = sync.reload.sync_stats
    assert stats["rate_limited"]
    assert_equal rate_limited_at.iso8601, stats["rate_limited_at"]
    assert_equal 1, stats["total_errors"]
  end

  test "records error stats on a generic failure" do
    sync = @item.syncs.create!
    EtoroItem::Importer.any_instance.expects(:import).raises(StandardError.new("Boom"))

    assert_raises(StandardError) { @syncer.perform_sync(sync) }

    assert_equal "Boom", sync.reload.sync_stats.dig("errors", 0, "message")
  end

  test "an account not held in USD fails the sync with a reason and keeps the keys in good standing" do
    sync = @item.syncs.create!
    Provider::Etoro.any_instance.stubs(:fetch_balances).returns({
      "balances" => [ { "accountId" => "etoro_trading_1", "accountType" => "Trading", "currency" => "EUR", "balance" => 100 } ]
    })
    Provider::Etoro.any_instance.expects(:fetch_portfolio).never

    assert_raises(Provider::Etoro::UnsupportedAccountError) { @syncer.perform_sync(sync) }

    assert @item.reload.good?
    assert_equal "sync_error", sync.reload.sync_stats.dig("errors", 0, "category")
    assert_match "EUR", sync.sync_stats.dig("errors", 0, "message")
  end

  test "perform_post_sync is a no-op" do
    assert_nil @syncer.perform_post_sync
  end
end
