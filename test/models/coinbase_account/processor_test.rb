require "test_helper"

class CoinbaseAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @coinbase_item = CoinbaseItem.create!(
      family: @family,
      name: "Test Coinbase",
      api_key: "test_key",
      api_secret: "test_secret"
    )
    @coinbase_account = @coinbase_item.coinbase_accounts.create!(
      name: "Bitcoin Wallet",
      account_id: "cb_btc_123",
      currency: "BTC",
      current_balance: 0.5
    )
  end

  test "process_holdings resolves and delegates to the holdings processor" do
    # Regression for issue #2412: the compact `class CoinbaseAccount::Processor`
    # definition means a bare HoldingsProcessor reference raised
    # NameError (uninitialized constant CoinbaseAccount::Processor::HoldingsProcessor)
    # on every sync, and the rescue in #process swallowed it, so holdings
    # silently never refreshed.
    CoinbaseAccount::HoldingsProcessor.any_instance.expects(:process).once

    processor = CoinbaseAccount::Processor.new(@coinbase_account)

    assert_nothing_raised do
      processor.send(:process_holdings)
    end
  end
end
