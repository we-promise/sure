require "test_helper"

class TruelayerAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @item = TruelayerItem.create!(family: @family, name: "Acme Bank", client_id: "test-client", client_secret: "secret", refresh_token: "r")
    @truelayer_account = @item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP", current_balance: 42.5)
    @account = Account.create!(family: @family, name: "Acc", balance: 0, currency: "GBP", accountable: Depository.new)
    AccountProvider.create!(account: @account, provider: @truelayer_account)
    @truelayer_account.reload
  end

  test "imports the good rows, counts the bad one and captures it for support" do
    @truelayer_account.update!(raw_transactions_payload: [
      txn("ok-1", "2026-03-01T10:00:00Z"),
      txn("bad", "not-a-date"),
      txn("ok-2", "2026-03-02T10:00:00Z")
    ])

    result = assert_difference -> { DebugLogEntry.with_provider_key("truelayer").count }, 1 do
      TruelayerAccount::Processor.new(@truelayer_account).process
    end

    assert_equal({ imported: 2, failed: 1 }, result.slice(:imported, :failed))
    assert_equal "bad", result[:errors].first[:transaction_id]
    assert_equal %w[truelayer_ok-1 truelayer_ok-2], @account.entries.where(source: "truelayer").order(:external_id).pluck(:external_id)
    assert_equal 42.5, @account.reload.balance
  end

  test "leaves out transactions before the connection's start date" do
    @item.update!(sync_start_date: Date.new(2026, 3, 2))
    @truelayer_account.update!(raw_transactions_payload: [ txn("old", "2026-03-01T10:00:00Z"), txn("new", "2026-03-02T00:30:00Z") ])

    result = TruelayerAccount::Processor.new(@truelayer_account).process

    assert_equal({ imported: 1, skipped: 1, failed: 0 }, result.slice(:imported, :skipped, :failed))
    assert_equal [ "truelayer_new" ], @account.entries.where(source: "truelayer").pluck(:external_id)
  end

  test "does nothing for an unlinked account" do
    unlinked = @item.truelayer_accounts.create!(account_id: "a2", name: "Other", currency: "GBP", raw_transactions_payload: [ txn("t", "2026-03-01T10:00:00Z") ])

    assert_nil TruelayerAccount::Processor.new(unlinked).process
  end

  private

    def txn(id, timestamp)
      { "transaction_id" => id, "timestamp" => timestamp, "amount" => -1, "currency" => "GBP", "description" => "x" }
    end
end
