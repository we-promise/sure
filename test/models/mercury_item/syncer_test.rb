# frozen_string_literal: true

require "test_helper"

class MercuryItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @mercury_item = mercury_items(:one)
    @syncer = MercuryItem::Syncer.new(@mercury_item)
  end

  test "marks sync healthy when import succeeds with no failures" do
    sync = recording_sync
    @mercury_item.expects(:import_latest_mercury_data).returns(
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
    @mercury_item.expects(:import_latest_mercury_data).returns(
      success: false,
      accounts_failed: 2,
      transactions_failed: 0
    )

    @syncer.perform_sync(sync)

    assert_equal [ [ I18n.t("mercury_items.syncer.accounts_failed", count: 2), "account_import_error" ] ],
                 sync.sync_stats["errors"].map { |e| e.values_at("message", "category") }
  end

  test "marks sync unhealthy when importer reports transactions_failed" do
    sync = recording_sync
    @mercury_item.expects(:import_latest_mercury_data).returns(
      success: false,
      accounts_failed: 0,
      transactions_failed: 3
    )

    @syncer.perform_sync(sync)

    assert_equal [ [ I18n.t("mercury_items.syncer.transactions_failed", count: 3), "transaction_import_error" ] ],
                 sync.sync_stats["errors"].map { |e| e.values_at("message", "category") }
  end

  test "an import that fails with the provider's own error reports that error" do
    sync = recording_sync
    @mercury_item.expects(:import_latest_mercury_data).returns(success: false, error: "Failed to fetch accounts data")

    @syncer.perform_sync(sync)

    assert_equal [ [ I18n.t("mercury_items.syncer.import_failed_with_error", error: "Failed to fetch accounts data"), "import_error" ] ],
                 sync.sync_stats["errors"].map { |e| e.values_at("message", "category") }
  end

  test "an import that raises stores a safe message and reraises it as SafeSyncError" do
    sync = recording_sync
    @mercury_item.expects(:import_latest_mercury_data).raises(StandardError, "boom")
    Sentry.expects(:capture_exception).once

    error = assert_raises(MercuryItem::Syncer::SafeSyncError) do
      @syncer.perform_sync(sync)
    end

    assert_equal I18n.t("mercury_items.syncer.failed"), error.message
    assert_equal [ [ I18n.t("mercury_items.syncer.failed"), "sync_error" ] ],
                 sync.sync_stats["errors"].map { |e| e.values_at("message", "category") }
  end

  test "a failed sync reaches Sentry once, without the safe error carrying it as its cause" do
    error = StandardError.new("raw provider failure")
    @mercury_item.stubs(:import_latest_mercury_data).raises(error)
    captured = []

    Sentry.stub(:capture_exception, ->(exception, *) { captured << exception }) do
      Sync.create!(syncable: @mercury_item).perform
    end

    safe_errors = captured.grep(MercuryItem::Syncer::SafeSyncError)
    assert_equal 1, safe_errors.size
    assert_nil safe_errors.first.cause
    reported = captured.flat_map { |exception| exception_chain(exception) }
    assert_equal 1, reported.count { |exception| exception.equal?(error) }
  end

  test "a failed sync records a debug log entry for support" do
    @mercury_item.expects(:import_latest_mercury_data).raises(RuntimeError, "connection reset")
    Sentry.stubs(:capture_exception)

    assert_difference -> { DebugLogEntry.where(provider_key: "mercury").count }, 1 do
      assert_raises(MercuryItem::Syncer::SafeSyncError) { @syncer.perform_sync(recording_sync) }
    end

    entry = DebugLogEntry.where(provider_key: "mercury").recent.first
    assert_equal [ "provider_sync_error", "error", "MercuryItem::Syncer" ], [ entry.category, entry.level, entry.source ]
    assert_equal @mercury_item.family, entry.family
    assert_equal({ "mercury_item_id" => @mercury_item.id, "error_class" => "RuntimeError", "error_message" => "connection reset" }, entry.metadata)
  end

  test "linked accounts that fail to process or schedule are reported" do
    mercury_account = mercury_accounts(:checking_account)
    account = @mercury_item.family.accounts.create!(name: "Linked", balance: 0, currency: "USD", accountable: Depository.new)
    AccountProvider.create!(account: account, provider: mercury_account)
    sync = Sync.create!(syncable: @mercury_item)
    @mercury_item.stubs(:import_latest_mercury_data).returns(success: true)
    @mercury_item.stubs(:process_accounts).returns([ { success: false, error: "bad row" } ])
    @mercury_item.stubs(:schedule_account_syncs).returns([ { success: true }, { success: false, error: "queue down" } ])

    @syncer.perform_sync(sync)

    assert_equal(
      [
        [ I18n.t("mercury_items.syncer.account_processing_failed", count: 1), "account_processing_error" ],
        [ I18n.t("mercury_items.syncer.account_sync_failed", count: 1), "account_sync_error" ]
      ],
      sync.reload.sync_stats["errors"].map { |e| e.values_at("message", "category") }
    )
  end

  test "the import starts from the sync's window" do
    sync = recording_sync
    sync.instance_variable_set(:@window_start_date, Date.new(2026, 9, 1))
    @mercury_item.expects(:import_latest_mercury_data).with(sync_start_date: Date.new(2026, 9, 1)).returns(success: true)

    @syncer.perform_sync(sync)
  end

  test "status text comes from the Mercury syncer translations" do
    I18n.backend.store_translations(:en, mercury_items: { syncer: { importing_accounts: "Fetching from Mercury" } })
    sync = recording_sync
    @mercury_item.stubs(:import_latest_mercury_data).returns(success: true)

    @syncer.perform_sync(sync)

    assert_includes sync.updates.filter_map { |update| update[:status_text] }, "Fetching from Mercury"
  ensure
    I18n.reload!
  end

  test "a rejected token fails the sync and flags the connection" do
    mercury_item = mercury_items(:one)
    Provider::Mercury.any_instance.stubs(:get_accounts)
                     .raises(Provider::Mercury::MercuryError.new("Invalid API token", :unauthorized))
    sync = Sync.create!(syncable: mercury_item)

    sync.perform

    assert sync.reload.failed?, "expected the sync to fail, was #{sync.status}"
    assert_equal I18n.t("mercury_items.syncer.credentials_invalid"), sync.error
    assert mercury_item.reload.requires_update?
  end

  private

    def exception_chain(exception)
      chain = []
      while exception
        chain << exception
        exception = exception.cause
      end
      chain
    end

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
