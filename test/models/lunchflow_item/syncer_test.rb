# frozen_string_literal: true

require "test_helper"

class LunchflowItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @lunchflow_item = lunchflow_items(:one)
    @syncer = LunchflowItem::Syncer.new(@lunchflow_item)
  end

  test "marks sync healthy when import succeeds with no failures" do
    sync = recording_sync
    @lunchflow_item.expects(:import_latest_lunchflow_data).returns(
      success: true,
      accounts_failed: 0,
      transactions_failed: 0
    )

    @syncer.perform_sync(sync)

    assert_equal 0, sync.sync_stats["total_errors"]
    assert_nil sync.sync_stats["errors"]
  end

  test "marks sync unhealthy when importer reports accounts_failed" do
    sync = recording_sync
    @lunchflow_item.expects(:import_latest_lunchflow_data).returns(
      success: false,
      accounts_failed: 2,
      transactions_failed: 0
    )

    @syncer.perform_sync(sync)

    assert_equal 1, sync.sync_stats["total_errors"]
    assert_equal(
      [ I18n.t("lunchflow_items.syncer.accounts_failed", count: 2) ],
      sync.sync_stats["errors"].map { |e| e["message"] }
    )
    assert_equal "account_import_error", sync.sync_stats["errors"].first["category"]
  end

  test "marks sync unhealthy when importer reports transactions_failed" do
    sync = recording_sync
    @lunchflow_item.expects(:import_latest_lunchflow_data).returns(
      success: false,
      accounts_failed: 0,
      transactions_failed: 3
    )

    @syncer.perform_sync(sync)

    assert_equal 1, sync.sync_stats["total_errors"]
    assert_equal(
      [ I18n.t("lunchflow_items.syncer.transactions_failed", count: 3) ],
      sync.sync_stats["errors"].map { |e| e["message"] }
    )
    assert_equal "transaction_import_error", sync.sync_stats["errors"].first["category"]
  end

  test "records both failure categories when accounts and transactions both fail" do
    sync = recording_sync
    @lunchflow_item.expects(:import_latest_lunchflow_data).returns(
      success: false,
      accounts_failed: 1,
      transactions_failed: 4
    )

    @syncer.perform_sync(sync)

    assert_equal 2, sync.sync_stats["total_errors"]
    assert_equal(
      [
        I18n.t("lunchflow_items.syncer.accounts_failed", count: 1),
        I18n.t("lunchflow_items.syncer.transactions_failed", count: 4)
      ],
      sync.sync_stats["errors"].map { |e| e["message"] }
    )
  end

  test "an import that raises stores a safe message and reraises it as SafeSyncError" do
    sync = recording_sync
    @lunchflow_item.expects(:import_latest_lunchflow_data).raises(StandardError, "boom")
    Sentry.expects(:capture_exception).once

    error = assert_raises(LunchflowItem::Syncer::SafeSyncError) do
      @syncer.perform_sync(sync)
    end

    assert_equal I18n.t("lunchflow_items.syncer.failed"), error.message
    assert_equal 1, sync.sync_stats["total_errors"]
    stored = sync.sync_stats["errors"].first
    assert_equal [ I18n.t("lunchflow_items.syncer.failed"), "sync_error" ], stored.values_at("message", "category")
  end

  test "an import that fails with the provider's own error reports that error" do
    sync = recording_sync
    @lunchflow_item.expects(:import_latest_lunchflow_data).returns(success: false, error: "Rate limited")

    @syncer.perform_sync(sync)

    assert_equal [ [ I18n.t("lunchflow_items.syncer.import_failed_with_error", error: "Rate limited"), "import_error" ] ],
                 sync.sync_stats["errors"].map { |e| e.values_at("message", "category") }
  end

  test "a failed sync records a debug log entry for support" do
    @lunchflow_item.expects(:import_latest_lunchflow_data).raises(RuntimeError, "connection reset")
    Sentry.stubs(:capture_exception)

    assert_difference -> { DebugLogEntry.where(provider_key: "lunchflow").count }, 1 do
      assert_raises(LunchflowItem::Syncer::SafeSyncError) { @syncer.perform_sync(recording_sync) }
    end

    entry = DebugLogEntry.where(provider_key: "lunchflow").recent.first
    assert_equal [ "provider_sync_error", "error", "LunchflowItem::Syncer" ], [ entry.category, entry.level, entry.source ]
    assert_equal @lunchflow_item.family, entry.family
    assert_equal({ "lunchflow_item_id" => @lunchflow_item.id, "error_class" => "RuntimeError", "error_message" => "connection reset" }, entry.metadata)
  end

  test "a failed import with no counts and no error text reports the generic failure" do
    sync = recording_sync
    @lunchflow_item.expects(:import_latest_lunchflow_data).returns(success: false)

    @syncer.perform_sync(sync)

    assert_equal [ [ I18n.t("lunchflow_items.syncer.import_failed"), "import_error" ] ],
                 sync.sync_stats["errors"].map { |e| e.values_at("message", "category") }
  end

  test "linked accounts that fail to process or schedule are reported" do
    lunchflow_account = @lunchflow_item.lunchflow_accounts.first
    account = @lunchflow_item.family.accounts.create!(name: "Linked", balance: 0, currency: "USD", accountable: Depository.new)
    AccountProvider.create!(account: account, provider: lunchflow_account)
    sync = Sync.create!(syncable: @lunchflow_item)
    @lunchflow_item.stubs(:import_latest_lunchflow_data).returns(success: true)
    @lunchflow_item.stubs(:process_accounts).returns([ { success: false, error: "bad row" } ])
    @lunchflow_item.stubs(:schedule_account_syncs).returns([ { success: true }, { success: false, error: "queue down" } ])

    @syncer.perform_sync(sync)

    assert_equal(
      [
        [ I18n.t("lunchflow_items.syncer.account_processing_failed", count: 1), "account_processing_error" ],
        [ I18n.t("lunchflow_items.syncer.account_sync_failed", count: 1), "account_sync_error" ]
      ],
      sync.reload.sync_stats["errors"].map { |e| e.values_at("message", "category") }
    )
  end

  test "the import starts from the sync's window" do
    sync = recording_sync
    sync.instance_variable_set(:@window_start_date, Date.new(2026, 9, 1))
    @lunchflow_item.expects(:import_latest_lunchflow_data).with(sync_start_date: Date.new(2026, 9, 1)).returns(success: true)

    @syncer.perform_sync(sync)
  end

  test "status text comes from the Lunch Flow syncer translations" do
    I18n.backend.store_translations(:en, lunchflow_items: { syncer: { importing_accounts: "Fetching from Lunch Flow" } })
    sync = recording_sync
    @lunchflow_item.stubs(:import_latest_lunchflow_data).returns(success: true)

    @syncer.perform_sync(sync)

    assert_includes sync.updates.filter_map { |update| update[:status_text] }, "Fetching from Lunch Flow"
  ensure
    I18n.reload!
  end

  test "a rejected API key fails the sync and flags the connection" do
    Provider::Lunchflow.any_instance.stubs(:get_accounts)
                       .raises(Provider::Lunchflow::LunchflowError.new("Invalid API key", :unauthorized, status: 401))
    sync = Sync.create!(syncable: @lunchflow_item)

    sync.perform

    assert sync.reload.failed?, "expected the sync to fail, was #{sync.status}"
    assert_equal I18n.t("lunchflow_items.syncer.credentials_invalid"), sync.error
    assert @lunchflow_item.reload.requires_update?
  end

  private

    def recording_sync
      Class.new do
        attr_accessor :sync_stats, :status_text
        attr_reader :updates, :window_start_date, :window_end_date

        def initialize
          @sync_stats = {}
          @updates = []
          @window_start_date = nil
          @window_end_date = nil
        end

        def update!(attributes)
          @updates << attributes
          self.sync_stats = attributes[:sync_stats] if attributes.key?(:sync_stats)
          self.status_text = attributes[:status_text] if attributes.key?(:status_text)
        end
      end.new
    end
end
