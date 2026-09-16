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
      [ I18n.t("provider_warnings.lunchflow_accounts_failed", count: 2) ],
      sync.sync_stats["errors"].map { |e| e["message"] }
    )
    assert_equal "lunchflow_import", sync.sync_stats["errors"].first["category"]
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
      [ I18n.t("provider_warnings.lunchflow_transactions_failed", count: 3) ],
      sync.sync_stats["errors"].map { |e| e["message"] }
    )
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
        I18n.t("provider_warnings.lunchflow_accounts_failed", count: 1),
        I18n.t("provider_warnings.lunchflow_transactions_failed", count: 4)
      ],
      sync.sync_stats["errors"].map { |e| e["message"] }
    )
  end

  test "captures sync_error category and reraises when import raises" do
    sync = recording_sync
    @lunchflow_item.expects(:import_latest_lunchflow_data).raises(StandardError, "boom")

    assert_raises(StandardError) do
      @syncer.perform_sync(sync)
    end

    assert_equal 1, sync.sync_stats["total_errors"]
    error = sync.sync_stats["errors"].first
    assert_equal "boom", error["message"]
    assert_equal "sync_error", error["category"]
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
