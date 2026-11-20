require "test_helper"

class FioItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @fio_item = FioItem.create!(family: @family, name: "Test Fio", token: "fio-token")
    @fio_account = FioAccount.create!(
      fio_item: @fio_item,
      name: "Fio banka 2400222222",
      fio_account_id: "2400222222",
      currency: "CZK"
    )
    @fio_item.stubs(:import_latest_fio_data).returns({ success: true })
  end

  test "reports an unlinked account as needing setup" do
    sync = sync_item

    assert_equal 1, sync.sync_stats["unlinked_accounts"]
    assert @fio_item.reload.pending_account_setup?
  end

  # Skipping an account in setup is an answer, not an omission. The status summary reads
  # the persisted stats in preference to the item's own counts, so an account left out of
  # them here would keep asking to be set up after the user declined.
  test "stops counting an account the user skipped" do
    @fio_account.update!(ignored: true)

    sync = sync_item

    assert_equal 1, sync.sync_stats["total_accounts"]
    assert_equal 0, sync.sync_stats["unlinked_accounts"]
    refute @fio_item.reload.pending_account_setup?
  end

  # A connection is linked between its discovery sync and the next one, on the same
  # in-memory record. Counts memoized during the first sync must not outlive it.
  test "counts an account linked since the last sync as linked" do
    sync_item

    account = Account.create!(
      family: @family, name: "Fio", accountable: Depository.new(subtype: "checking"),
      balance: 0, currency: "CZK"
    )
    AccountProvider.create!(account: account, provider: @fio_account)

    sync = sync_item

    assert_equal 1, sync.sync_stats["linked_accounts"]
    assert_equal 0, sync.sync_stats["unlinked_accounts"]
  end

  private

    def sync_item
      sync = Sync.create!(syncable: @fio_item)
      FioItem::Syncer.new(@fio_item.reload).perform_sync(sync)
      sync.reload
    end
end
