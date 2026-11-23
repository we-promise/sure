# frozen_string_literal: true

require "test_helper"

class WiseItem::SyncerTest < ActiveSupport::TestCase
  test "a rejected token fails the sync and flags the connection" do
    wise_item = wise_items(:one)
    Provider::Wise.any_instance.stubs(:get_balances)
                  .raises(Provider::Wise::WiseError.new("Invalid API token", :unauthorized))
    sync = Sync.create!(syncable: wise_item)

    sync.perform

    assert sync.reload.failed?, "expected the sync to fail, was #{sync.status}"
    assert_equal I18n.t("wise_items.syncer.credentials_invalid"), sync.error
    assert wise_item.reload.requires_update?
  end

  test "a failed sync reaches Sentry once, without the safe error carrying it as its cause" do
    wise_item = wise_items(:one)
    error = StandardError.new("raw provider failure")
    WiseItem.any_instance.stubs(:import_latest_wise_data).raises(error)
    sync = Sync.create!(syncable: wise_item)
    captured = []

    Sentry.stub(:capture_exception, ->(exception, *) { captured << exception }) do
      sync.perform
    end

    safe_errors = captured.grep(WiseItem::Syncer::SafeSyncError)
    assert_equal 1, safe_errors.size
    assert_nil safe_errors.first.cause
    assert_equal 1, captured.flat_map { |exception| exception_chain(exception) }.count { |exception| exception.equal?(error) }
    assert_equal I18n.t("wise_items.syncer.failed"), sync.reload.error
  end

  # A failed fetch completed the sync with no error anywhere. It still
  # completes, but the error is in the sync stats the Wise card shows, and
  # processing is told the import was incomplete.
  test "reports failed fetches and withholds the complete flag from processing" do
    wise_item = linked_wise_item
    WiseItem.any_instance.stubs(:import_latest_wise_data)
            .returns(success: false, complete: false, fetch_failures: 2, accounts_failed: 0, transactions_failed: 0)
    WiseItem.any_instance.expects(:process_accounts).with(import_complete: false).returns([])
    WiseItem.any_instance.stubs(:schedule_account_syncs).returns([])
    sync = Sync.create!(syncable: wise_item)

    sync.perform

    assert sync.reload.completed?, "expected the sync to complete, was #{sync.status}"
    assert_equal 1, sync.sync_stats["total_errors"]
    assert_equal [ I18n.t("wise_items.syncer.fetch_failed", count: 2) ], sync.sync_stats["errors"].map { |error| error["message"] }
  end

  test "tells processing the import was complete when every fetch succeeded" do
    wise_item = linked_wise_item
    WiseItem.any_instance.stubs(:import_latest_wise_data)
            .returns(success: true, complete: true, fetch_failures: 0, accounts_failed: 0, transactions_failed: 0)
    WiseItem.any_instance.expects(:process_accounts).with(import_complete: true).returns([])
    WiseItem.any_instance.stubs(:schedule_account_syncs).returns([])
    sync = Sync.create!(syncable: wise_item)

    sync.perform

    assert_equal 0, sync.reload.sync_stats["total_errors"]
  end

  # A full re-fetch (coverage_upgraded) is no longer passed on; the balances
  # it rebuilt keep their cap bypass themselves
  # (WiseAccount#prune_cap_bypass_ids).
  test "records the stale entries processing deleted" do
    wise_item = linked_wise_item
    WiseItem.any_instance.stubs(:import_latest_wise_data)
            .returns(success: true, complete: true, coverage_upgraded: true, fetch_failures: 0, accounts_failed: 0, transactions_failed: 0)
    WiseItem.any_instance.expects(:process_accounts).with(import_complete: true).returns([
      { wise_account_id: 1, success: true, result: { imported: 3, skipped: 0, failed: 0, pruned: 2 } },
      { wise_account_id: 2, success: true, result: { imported: 1, skipped: 0, failed: 0, pruned: 1 } },
      { wise_account_id: 3, success: true, result: nil }
    ])
    WiseItem.any_instance.stubs(:schedule_account_syncs).returns([])
    sync = Sync.create!(syncable: wise_item)

    sync.perform

    assert_equal 3, sync.reload.sync_stats["wise_pruned_entries"]
    summary = DebugLogEntry.where(provider_key: "wise", source: "WiseItem::Syncer").order(:created_at).last
    assert_equal 3, summary.metadata["pruned_entry_count"]
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

    def linked_wise_item
      wise_item = wise_items(:one)
      account = Account.create!(family: wise_item.family, name: "Wise EUR", balance: 0, currency: "EUR",
                                accountable: Depository.new(subtype: "checking"))
      AccountProvider.create!(account: account, provider: wise_accounts(:checking))
      wise_item
    end
end
