require "test_helper"

class EnableBankingItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @item = EnableBankingItem.create!(
      family: families(:dylan_family),
      name: "Test",
      country_code: "DE",
      application_id: "app",
      client_certificate: "cert",
      session_id: "sess",
      session_expires_at: 1.day.ago, # expired
      status: :good
    )
    @syncer = EnableBankingItem::Syncer.new(@item)
  end

  test "expired session marks requires_update and finishes gracefully without raising" do
    sync = Sync.create!(syncable: @item)

    assert_nothing_raised do
      @syncer.perform_sync(sync)
    end

    assert @item.reload.requires_update?

    stats = sync.reload.sync_stats || {}
    assert_equal 0, (stats["total_errors"] || 0),
      "Expired session should be a graceful reconnect state, not a red sync error"
  end

  test "an expired session still purges stale early-fetched rows" do
    eba = EnableBankingAccount.create!(
      enable_banking_item: @item, name: "Skipped", uid: "skipped_uid", account_id: "skipped-uuid", currency: "EUR"
    )
    eba.update_columns(raw_transactions_payload: [ { transaction_id: "a", booking_date: "2020-01-01" } ],
                       early_fetched_at: (EnableBankingItem::Importer::UNLINKED_TRANSACTIONS_RETENTION + 1.day).ago)

    @syncer.perform_sync(Sync.create!(syncable: @item))

    assert_nil eba.reload.raw_transactions_payload, "early rows outlived the retention while the session was expired"
  end

  test "a sync whose session the bank rejects still purges stale early-fetched rows" do
    @item.update!(session_expires_at: 1.day.from_now)
    eba = EnableBankingAccount.create!(
      enable_banking_item: @item, name: "Skipped", uid: "skipped_uid", account_id: "skipped-uuid", currency: "EUR"
    )
    eba.update_columns(raw_transactions_payload: [ { transaction_id: "a", booking_date: "2020-01-01" } ],
                       early_fetched_at: (EnableBankingItem::Importer::UNLINKED_TRANSACTIONS_RETENTION + 1.day).ago)
    # A session revoked at the bank: valid locally, but GET /sessions fails.
    @item.stubs(:import_latest_enable_banking_data).returns(success: false, error: "Session invalid")

    assert_raises(StandardError) { @syncer.perform_sync(Sync.create!(syncable: @item)) }

    assert_nil eba.reload.raw_transactions_payload, "early rows outlived the retention while the bank rejected the session"
  end

  test "post-sync queues one more sync for a request that arrived after the last sync" do
    Sync.create!(syncable: @item, status: "completed", completed_at: 1.minute.ago, created_at: 3.minutes.ago)
    # Written by the callback in another process; the syncer's item is not reloaded.
    EnableBankingItem.where(id: @item.id).update_all(full_history_fetch_requested_at: 2.minutes.ago)

    assert_difference -> { @item.syncs.count }, 1 do
      @syncer.perform_post_sync
    end
  end

  test "post-sync queues the follow-up sync only after the finalization transaction commits" do
    sync = Sync.create!(syncable: @item, status: "syncing", created_at: 3.minutes.ago)
    EnableBankingItem.where(id: @item.id).update_all(full_history_fetch_requested_at: 2.minutes.ago)
    # Transactions this code could still join when sync_later runs. The test's
    # own transaction can't be joined, so none means the finalization committed.
    open_transactions = []
    @item.define_singleton_method(:sync_later) do |*args, **kwargs|
      open_transactions << ActiveRecord.all_open_transactions.size
      super(*args, **kwargs)
    end

    Sync.transaction do
      sync.lock!
      sync.update!(status: "completed", completed_at: Time.current)
      @syncer.perform_post_sync
      assert_equal 1, @item.syncs.count, "sync_later ran while the sync row lock was held"
    end

    assert_equal 2, @item.syncs.count
    assert_equal [ 0 ], open_transactions, "sync_later ran before the finalization transaction committed"

    # A request newer than every sync, so only the rollback can stop sync_later.
    @item.syncs.update_all(created_at: 1.minute.ago)
    EnableBankingItem.where(id: @item.id).update_all(full_history_fetch_requested_at: Time.current)
    open_transactions.clear

    Sync.transaction do
      @syncer.perform_post_sync
      raise ActiveRecord::Rollback
    end
    assert_empty open_transactions, "sync_later ran although the finalization transaction rolled back"

    # The same request outside a transaction does queue, so the check above can fail.
    @syncer.perform_post_sync
    assert_equal [ 0 ], open_transactions
  end

  test "post-sync sees a request committed after it was called but before finalization commits" do
    sync = Sync.create!(syncable: @item, status: "syncing", created_at: 3.minutes.ago)

    Sync.transaction do
      sync.lock!
      sync.update!(status: "completed", completed_at: Time.current)
      @syncer.perform_post_sync
      # The callback commits its request now; its sync_later reused this sync.
      EnableBankingItem.where(id: @item.id).update_all(full_history_fetch_requested_at: Time.current)
    end

    assert_equal 2, @item.syncs.count, "the late request waited for a later sync"
  end

  test "an error queueing the follow-up sync is reported and the parent sync still finalizes" do
    family_sync = Sync.create!(syncable: @item.family, status: "syncing")
    item_sync = Sync.create!(syncable: @item, parent: family_sync, status: "syncing", created_at: 3.minutes.ago)
    EnableBankingItem.where(id: @item.id).update_all(full_history_fetch_requested_at: 2.minutes.ago)
    error = StandardError.new("redis down")
    EnableBankingItem.any_instance.stubs(:sync_later).raises(error)
    Sentry.expects(:capture_exception).with(error)

    assert_nothing_raised { item_sync.finalize_if_all_children_finalized }

    assert_equal "completed", item_sync.reload.status
    assert_equal "completed", family_sync.reload.status
  end

  test "post-sync does not queue a sync for a request the last sync already saw, or a stale one" do
    @item.update_columns(full_history_fetch_requested_at: 4.minutes.ago)
    Sync.create!(syncable: @item, status: "completed", completed_at: 1.minute.ago, created_at: 3.minutes.ago)

    assert_no_difference -> { @item.syncs.count } do
      @syncer.perform_post_sync
    end

    @item.update_columns(full_history_fetch_requested_at: (EnableBankingItem::Importer::FULL_HISTORY_REQUEST_WINDOW + 1.minute).ago)
    @item.syncs.update_all(created_at: 2.hours.ago)
    assert_no_difference -> { @item.syncs.count } do
      @syncer.perform_post_sync
    end
  end

  test "a truncated full-history fetch is recorded as a data warning on the sync" do
    @item.update!(session_expires_at: 1.day.from_now)
    @item.stubs(:import_latest_enable_banking_data).returns(success: true, transactions_truncated: 1)
    sync = Sync.create!(syncable: @item)

    @syncer.perform_sync(sync)

    stats = sync.reload.sync_stats
    assert_equal 1, stats["data_warnings"]
    assert_match(/older transactions may be missing/, stats["data_quality_details"].first["message"])
    assert_equal 0, stats["total_errors"]
  end

  test "a truncated full-history fetch is recorded even when another account fails" do
    @item.update!(session_expires_at: 1.day.from_now)
    @item.stubs(:import_latest_enable_banking_data).returns(success: false, transactions_failed: 1, transactions_truncated: 1)
    sync = Sync.create!(syncable: @item)

    assert_raises(StandardError) { @syncer.perform_sync(sync) }

    assert_equal 1, sync.reload.sync_stats["data_warnings"]
  end
end
