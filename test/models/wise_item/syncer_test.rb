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

  private

    def linked_wise_item
      wise_item = wise_items(:one)
      account = Account.create!(family: wise_item.family, name: "Wise EUR", balance: 0, currency: "EUR",
                                accountable: Depository.new(subtype: "checking"))
      AccountProvider.create!(account: account, provider: wise_accounts(:checking))
      wise_item
    end
end
