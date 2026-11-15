require "test_helper"

class TradeRepublicRepairJobTest < ActiveJob::TestCase
  test "skips provider accounts linked to a disabled account" do
    item = trade_republic_items(:configured_item)
    item.trade_republic_accounts.destroy_all
    provider_account = item.trade_republic_accounts.create!(
      name: "Trade Republic Crypto", kind: "crypto", trade_republic_account_id: "crypto:DE1", currency: "EUR"
    )
    account = item.family.accounts.create!(
      name: "Trade Republic Crypto", balance: 0, currency: "EUR", accountable: Crypto.new(subtype: "exchange")
    )
    provider_account.ensure_account_provider!(account)
    account.disable!

    TradeRepublicAccount::Processor.expects(:new).never

    TradeRepublicRepairJob.perform_now(item)
  end
end
