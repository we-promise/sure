require "test_helper"

class TradeRepublicAccountProcessorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "sets the current balance anchor without scheduling an account sync" do
    provider_account = trade_republic_accounts(:cash_account)
    account = provider_account.trade_republic_item.family.accounts.create!(
      name: "TR Cash", balance: 0, currency: "EUR", accountable: Depository.new
    )
    provider_account.ensure_account_provider!(account)

    assert_no_difference -> { account.syncs.count } do
      assert_no_enqueued_jobs only: SyncJob do
        TradeRepublicAccount::Processor.new(provider_account.reload).process
      end
    end

    assert account.reload.has_current_anchor?
    assert_equal BigDecimal("500"), account.current_anchor_balance.to_d
  end
end
