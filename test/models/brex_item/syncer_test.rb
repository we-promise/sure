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
