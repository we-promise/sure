# frozen_string_literal: true

require "test_helper"

class CoinbaseAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")
    @item = CoinbaseItem.create!(
      family: @family,
      name: "Coinbase",
      api_key: "k",
      api_secret: "s"
    )
    @coinbase_account = @item.coinbase_accounts.create!(
      name: "Bitcoin Wallet",
      account_id: "cb_btc_123",
      currency: "BTC",
      current_balance: 0.5,
      raw_payload: { "native_balance" => { "amount" => "25000", "currency" => "USD" } }
    )
    @account = Account.create!(
      family: @family,
      name: "Coinbase BTC",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @coinbase_account)
    @coinbase_account.reload
  end

  # Regression for issue #2412: the bare `HoldingsProcessor` reference resolved
  # as CoinbaseAccount::Processor::HoldingsProcessor and raised an uninitialized
  # constant error that was swallowed, so holdings never refreshed.
  test "process invokes CoinbaseAccount::HoldingsProcessor" do
    CoinbaseAccount::HoldingsProcessor.any_instance.expects(:process).once

    CoinbaseAccount::Processor.new(@coinbase_account).process
  end

  test "updates linked crypto account balance from native_balance" do
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)

    CoinbaseAccount::Processor.new(@coinbase_account).process

    @account.reload
    assert_equal 25_000.to_d, @account.balance
    assert_equal 0.to_d, @account.cash_balance
    assert_equal "USD", @account.currency
  end
end
