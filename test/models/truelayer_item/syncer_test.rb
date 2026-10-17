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
