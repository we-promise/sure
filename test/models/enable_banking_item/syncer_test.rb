require "test_helper"

class EnableBankingItem::SyncerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

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

  test "a throttled import defers without reporting a generic failure or losing authorization" do
    @item.update!(session_expires_at: 1.day.from_now)
    link_visible_account!
    previous_success = @item.last_successful_sync_at
    error = Provider::EnableBanking::EnableBankingError.new("limited", :rate_limited, http_status: 429)
    @item.expects(:import_latest_enable_banking_data).once.raises(error)
    sync = Sync.create!(syncable: @item)
    assert_enqueued_with(job: EnableBankingSyncRetryJob) do
      sync.perform
    end
    assert sync.reload.completed?
    assert sync.completed_at
    assert @item.reload.sync_retry_pending?
    assert @item.session_valid?
    assert_equal previous_success, @item.last_successful_sync_at
    assert_equal true, sync.sync_stats["deferred"]
    assert_equal true, sync.sync_stats["rate_limited"]
    assert_equal 0, sync.sync_stats["total_errors"]
    assert_nil @item.last_synced_at
  end

  test "a partial balance refresh retains the earlier successful timestamp" do
    previous_success = 2.days.ago
    @item.update!(session_expires_at: 1.day.from_now, last_successful_sync_at: previous_success)
    link_visible_account!
    @item.expects(:import_latest_enable_banking_data).once.returns(
      success: true, accounts_failed: 0, balances_failed: 1, transactions_failed: 0, transactions_imported: 3
    )
    @item.stubs(:process_accounts).returns([ { success: true } ])
    @item.stubs(:schedule_account_syncs).returns([])
    sync = Sync.create!(syncable: @item)

    sync.perform

    assert sync.reload.completed?, sync.error.inspect
    assert_equal previous_success.to_i, @item.reload.last_successful_sync_at.to_i
    assert_equal true, sync.sync_stats["partial_import"]
    assert_equal 1, sync.sync_stats.dig("partial_import_counts", "balances_failed")
    assert_equal 1, sync.sync_stats["total_errors"]
    @item.update_column(:last_successful_sync_at, nil)
    assert_nil @item.last_successful_sync_at, "a completed partial sync must not be treated as a successful refresh by the historical fallback"
  end

  test "a complete import advances the successful timestamp" do
    @item.update!(session_expires_at: 1.day.from_now)
    link_visible_account!
    @item.expects(:import_latest_enable_banking_data).once.returns(
      success: true, accounts_failed: 0, balances_failed: 0, transactions_failed: 0
    )
    @item.stubs(:process_accounts).returns([ { success: true } ])
    @item.stubs(:schedule_account_syncs).returns([])
    sync = Sync.create!(syncable: @item)

    sync.perform

    assert sync.reload.completed?, sync.error.inspect
    assert_operator @item.reload.last_successful_sync_at, :>=, sync.created_at
    assert_equal true, sync.sync_stats["data_import_success"]
  end

  test "a permanent failure during retry clears the waiting state" do
    @item.update!(session_expires_at: 1.day.from_now, sync_retry_reason: "temporary_error", sync_retry_count: 1)
    link_visible_account!
    @item.expects(:import_latest_enable_banking_data).returns(success: false, error: "Invalid bank data")
    sync = Sync.create!(syncable: @item)
    sync.perform
    assert sync.reload.failed?
    assert_not @item.reload.sync_retry_pending?
    assert_equal 0, @item.sync_retry_count
  end

  test "a catalog-only sync does not reserve a data cycle or mark the import fresh" do
    @item.update!(session_expires_at: 1.day.from_now, aspsp_name: "Test Bank")
    @item.enable_banking_accounts.create!(name: "Unlinked", uid: "catalog-uid", currency: "EUR")
    @item.enable_banking_sync_budget
    @item.expects(:reserve_sync_slot!).never
    @item.expects(:import_latest_enable_banking_data).never
    sync = Sync.create!(syncable: @item)

    sync.perform

    assert sync.reload.completed?
    assert_equal true, sync.sync_stats["catalog_only"]
    assert_equal "account_setup_required", sync.sync_stats["deferred_reason"]
    assert @item.reload.pending_account_setup?
    assert_nil @item.next_sync_at
    assert_nil @item.next_background_sync_at
    assert_nil @item.last_successful_sync_at
  end

  private

    def link_visible_account!
      provider_account = @item.enable_banking_accounts.create!(
        name: "Checking", uid: SecureRandom.hex(8), account_id: SecureRandom.uuid,
        currency: "EUR", current_balance: 100, account_status: "active", provider: "enable_banking"
      )
      account = Account.create!(
        family: @item.family, name: "Checking", currency: "EUR", balance: 100,
        cash_balance: 100, accountable: Depository.create!(subtype: "checking")
      )
      AccountProvider.create!(account: account, provider: provider_account)
      provider_account
    end
end
