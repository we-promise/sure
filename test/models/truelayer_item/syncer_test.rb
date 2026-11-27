require "test_helper"

class TruelayerItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @item = TruelayerItem.create!(family: @family, name: "Acme Bank", client_id: "test-client", client_secret: "secret", refresh_token: "r")
    @syncer = TruelayerItem::Syncer.new(@item)
  end

  test "a clean import is healthy" do
    sync = recording_sync
    @item.expects(:import_latest_truelayer_data).returns(success: true, accounts_failed: 0, transactions_failed: 0, balances_failed: 0)

    @syncer.perform_sync(sync)

    assert_equal 0, sync.sync_stats["total_errors"]
    assert_nil sync.sync_stats["errors"]
  end

  test "import failures and account processing failures both reach sync health" do
    sync = recording_sync
    truelayer_account = @item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP")
    account = Account.create!(family: @family, name: "Acc", balance: 0, currency: "GBP", accountable: Depository.new)
    AccountProvider.create!(account: account, provider: truelayer_account)

    @item.expects(:import_latest_truelayer_data).returns(success: false, accounts_failed: 0, transactions_failed: 1, balances_failed: 0)
    @item.expects(:process_accounts).returns([
      { truelayer_account_id: "x", success: false, error: "boom" },
      { truelayer_account_id: "y", success: true, result: { imported: 3, failed: 2, errors: [] } }
    ])
    @item.stubs(:schedule_account_syncs).returns([])

    @syncer.perform_sync(sync)

    messages = sync.sync_stats["errors"].map { |e| e["message"] }
    assert_includes messages, I18n.t("provider_warnings.truelayer_transactions_failed", count: 1)
    assert_includes messages, I18n.t("provider_warnings.truelayer_processing_failed", count: 1)
    assert_includes messages, I18n.t("provider_warnings.truelayer_entries_failed", count: 2)
    assert_equal 3, sync.sync_stats["total_errors"]
  end

  test "accounts whose balance sync could not be queued reach sync health" do
    sync = recording_sync
    truelayer_account = @item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP")
    account = Account.create!(family: @family, name: "Acc", balance: 0, currency: "GBP", accountable: Depository.new)
    AccountProvider.create!(account: account, provider: truelayer_account)

    @item.expects(:import_latest_truelayer_data).returns(success: true, accounts_failed: 0, transactions_failed: 0, balances_failed: 0)
    @item.expects(:process_accounts).returns([ { truelayer_account_id: "a1", success: true, result: { imported: 1, failed: 0, errors: [] } } ])
    @item.expects(:schedule_account_syncs).returns([ { account_id: account.id, success: false, error: "enqueue failed" } ])

    @syncer.perform_sync(sync)

    assert_equal [ I18n.t("provider_warnings.truelayer_scheduling_failed", count: 1) ], sync.sync_stats["errors"].map { |e| e["message"] }
    assert_equal 1, sync.sync_stats["total_errors"]
  end

  test "a consent completed during a sync queues another sync while full history is still available" do
    sync = @item.syncs.create!
    travel 1.second do
      @item.update!(last_authorized_at: Time.current, history_backfilled_at: nil)
      @item.expects(:sync_later).once

      @syncer.perform_post_sync
    end
  ensure
    sync&.destroy
  end

  test "a sync that began after the consent does not queue another one" do
    @item.update!(last_authorized_at: Time.current, history_backfilled_at: nil)
    sync = nil
    travel 1.second do
      sync = @item.syncs.create!
      @item.expects(:sync_later).never

      @syncer.perform_post_sync
    end
  ensure
    sync&.destroy
  end

  test "no follow-up sync once the backfill is done or the history window has closed" do
    sync = @item.syncs.create!
    @item.expects(:sync_later).never

    @item.update!(last_authorized_at: 1.second.from_now, history_backfilled_at: Time.current)
    @syncer.perform_post_sync

    @item.update!(last_authorized_at: (TruelayerItem::FULL_HISTORY_WINDOW + 1.minute).ago, history_backfilled_at: nil)
    @syncer.perform_post_sync
  ensure
    sync&.destroy
  end

  private

    def recording_sync
      Class.new do
        attr_accessor :sync_stats, :status_text
        attr_reader :created_at, :window_start_date, :window_end_date

        def initialize
          @sync_stats = {}
          @created_at = Time.current
        end

        def update!(attributes)
          self.sync_stats = attributes[:sync_stats] if attributes.key?(:sync_stats)
          self.status_text = attributes[:status_text] if attributes.key?(:status_text)
        end
      end.new
    end
end
