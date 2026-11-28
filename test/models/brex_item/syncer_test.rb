# frozen_string_literal: true

require "test_helper"

class BrexItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @brex_item = brex_items(:one)
    @syncer = BrexItem::Syncer.new(@brex_item)
  end

  test "passes sync window start date to importer" do
    window_start_date = Date.new(2026, 2, 1)
    sync = mock_sync(window_start_date: window_start_date)

    @brex_item.expects(:import_latest_brex_data).with(sync_start_date: window_start_date).once

    @syncer.perform_sync(sync)
  end

  test "records localized setup status text and counts" do
    window_start_date = Date.new(2026, 2, 1)
    sync = recording_sync(window_start_date: window_start_date)

    @brex_item.expects(:import_latest_brex_data).with(sync_start_date: window_start_date).once

    @syncer.perform_sync(sync)

    assert_equal [
      I18n.t("brex_items.syncer.importing_accounts"),
      I18n.t("brex_items.syncer.checking_account_configuration"),
      I18n.t("brex_items.syncer.accounts_need_setup", count: 1)
    ], sync.updates.filter_map { |attrs| attrs[:status_text] }

    assert_equal 1, sync.sync_stats["total_accounts"]
    assert_equal 0, sync.sync_stats["linked_accounts"]
    assert_equal 1, sync.sync_stats["unlinked_accounts"]
  end

  test "records importer failure counts in health stats" do
    sync = recording_sync(window_start_date: Date.new(2026, 2, 1))
    @brex_item.expects(:import_latest_brex_data).returns(
      success: false,
      accounts_failed: 2,
      transactions_failed: 1
    )

    @syncer.perform_sync(sync)

    assert_equal 2, sync.sync_stats["total_errors"]
    assert_equal [
      I18n.t("brex_items.syncer.accounts_failed", count: 2),
      I18n.t("brex_items.syncer.transactions_failed", count: 1)
    ], sync.sync_stats["errors"].map { |error| error["message"] }
  end

  test "records account processing and scheduling failures in health stats" do
    account = @brex_item.family.accounts.create!(
      name: "Linked Brex Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    brex_account = @brex_item.brex_accounts.first
    AccountProvider.create!(account: account, provider: brex_account)

    sync = recording_sync(window_start_date: Date.new(2026, 2, 1))
    @brex_item.expects(:import_latest_brex_data).returns(
      success: true,
      accounts_failed: 0,
      transactions_failed: 0
    )
    @brex_item.expects(:process_accounts).returns([
      { brex_account_id: brex_account.id, success: false, error: "processing failure" }
    ])
    @brex_item.expects(:schedule_account_syncs).returns([
      { account_id: account.id, success: false, error: "scheduling failure" }
    ])

    @syncer.perform_sync(sync)

    assert_equal 2, sync.sync_stats["total_errors"]
    assert_equal [
      I18n.t("brex_items.syncer.account_processing_failed", count: 1),
      I18n.t("brex_items.syncer.account_sync_failed", count: 1)
    ], sync.sync_stats["errors"].map { |error| error["message"] }
  end

  test "counts only the linked account's Brex-sourced transactions" do
    account = @brex_item.family.accounts.create!(name: "Linked Brex Checking", balance: 0, currency: "USD", accountable: Depository.new)
    AccountProvider.create!(account: account, provider: @brex_item.brex_accounts.first)
    @brex_item.stubs(:import_latest_brex_data).returns(success: true)
    @brex_item.stubs(:process_accounts).returns([])
    @brex_item.stubs(:schedule_account_syncs).returns([])
    sync = recording_sync(window_start_date: Date.new(2026, 2, 1))

    account.entries.create!(name: "Brex card charge", date: Date.current, amount: 10, currency: "USD", source: "brex", entryable: Transaction.new)
    account.entries.create!(name: "Manual entry", date: Date.current, amount: 20, currency: "USD", entryable: Transaction.new)
    account.entries.create!(name: "Second manual entry", date: Date.current, amount: 30, currency: "USD", entryable: Transaction.new)

    @syncer.perform_sync(sync)

    assert_equal 1, sync.sync_stats["tx_imported"]
    assert_equal 1, sync.sync_stats["tx_seen"]
  end

  test "tags the Sentry report with the Brex item id and the sync id" do
    sync = mock_sync(window_start_date: Date.new(2026, 2, 1))
    sync.stubs(:respond_to?).with(:id).returns(true)
    sync.stubs(:id).returns(42)
    @brex_item.expects(:import_latest_brex_data).raises(RuntimeError, "connection reset")
    scope = mock("scope")
    scope.expects(:set_tags).with(brex_item_id: @brex_item.id, sync_id: 42).once
    Sentry.expects(:capture_exception).yields(scope)

    assert_raises(BrexItem::Syncer::SafeSyncError) { @syncer.perform_sync(sync) }
  end

  test "raises user safe credential error for Brex auth failures" do
    sync = mock_sync(window_start_date: Date.new(2026, 2, 1))
    @brex_item.expects(:import_latest_brex_data)
              .raises(Provider::Brex::BrexError.new("raw upstream auth body", :unauthorized, http_status: 401))
    Sentry.expects(:capture_exception)

    error = assert_raises(BrexItem::Syncer::SafeSyncError) do
      @syncer.perform_sync(sync)
    end

    assert_equal I18n.t("brex_items.syncer.credentials_invalid"), error.message
  end

  test "a failed sync records a debug log entry for support" do
    sync = mock_sync(window_start_date: Date.new(2026, 2, 1))
    @brex_item.expects(:import_latest_brex_data).raises(RuntimeError, "connection reset")
    Sentry.stubs(:capture_exception)

    assert_difference -> { DebugLogEntry.where(provider_key: "brex").count }, 1 do
      assert_raises(BrexItem::Syncer::SafeSyncError) { @syncer.perform_sync(sync) }
    end

    entry = DebugLogEntry.where(provider_key: "brex").recent.first
    assert_equal "provider_sync_error", entry.category
    assert_equal "error", entry.level
    assert_equal "BrexItem::Syncer", entry.source
    assert_equal @brex_item.family, entry.family
    assert_equal({ "brex_item_id" => @brex_item.id, "error_class" => "RuntimeError", "error_message" => "connection reset" }, entry.metadata)
  end

  test "a rejected token fails the sync and flags the connection" do
    Provider::Brex.any_instance.stubs(:get_accounts)
                  .raises(Provider::Brex::BrexError.new("Unauthorized", :unauthorized, http_status: 401))
    sync = Sync.create!(syncable: @brex_item)

    sync.perform

    assert sync.reload.failed?, "expected the sync to fail, was #{sync.status}"
    assert_equal I18n.t("brex_items.syncer.credentials_invalid"), sync.error
    assert @brex_item.reload.requires_update?
  end

  # Brex scopes accounts and transactions separately, so a token can list the
  # accounts and still be refused their transactions.
  test "a token refused transactions fails the sync and flags the connection" do
    account = @brex_item.family.accounts.create!(name: "Linked Brex Checking", balance: 0, currency: "USD", accountable: Depository.new)
    AccountProvider.create!(account: account, provider: brex_accounts(:checking_account))
    Provider::Brex.any_instance.stubs(:get_accounts).returns(accounts: [])
    Provider::Brex.any_instance.stubs(:get_cash_transactions)
                  .raises(Provider::Brex::BrexError.new("Access forbidden", :access_forbidden, http_status: 403))
    sync = Sync.create!(syncable: @brex_item)

    sync.perform

    assert sync.reload.failed?, "expected the sync to fail, was #{sync.status}"
    assert_equal I18n.t("brex_items.syncer.credentials_invalid"), sync.error
    assert @brex_item.reload.requires_update?
  end

  private

    def mock_sync(window_start_date:)
      sync = mock("sync")
      sync.stubs(:respond_to?).with(:status_text).returns(true)
      sync.stubs(:respond_to?).with(:sync_stats).returns(true)
      sync.stubs(:sync_stats).returns({})
      sync.stubs(:window_start_date).returns(window_start_date)
      sync.stubs(:window_end_date).returns(nil)
      sync.stubs(:update!)
      sync
    end

    def recording_sync(window_start_date:)
      Class.new do
        attr_accessor :sync_stats, :status_text
        attr_reader :updates

        define_method(:initialize) do |start_date|
          @window_start_date = start_date
          @window_end_date = nil
          @created_at = Time.current
          @sync_stats = {}
          @updates = []
        end

        attr_reader :window_start_date, :window_end_date, :created_at

        def update!(attributes)
          @updates << attributes
          self.sync_stats = attributes[:sync_stats] if attributes.key?(:sync_stats)
          self.status_text = attributes[:status_text] if attributes.key?(:status_text)
        end
      end.new(window_start_date)
    end
end
