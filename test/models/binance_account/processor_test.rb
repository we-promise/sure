# frozen_string_literal: true
require "test_helper"

class BinanceAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "EUR")

    @item = BinanceItem.create!(
      family: @family, name: "Binance", api_key: "k", api_secret: "s"
    )
    @ba = @item.binance_accounts.create!(
      name: "Binance", account_type: "combined", currency: "USD", current_balance: 1000
    )
    @account = Account.create!(
      family: @family,
      name:   "Binance",
      balance: 0,
      currency: "EUR",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @ba)

    BinanceAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    @ba.stubs(:binance_item).returns(
      stub(binance_provider: nil, family: @family)
    )
  end

  test "converts USD balance to family currency when exact rate exists" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR",
                         date: Date.current, rate: 0.92)

    BinanceAccount::Processor.new(@ba).process

    @account.reload
    assert_equal "EUR", @account.currency
    assert_in_delta 920.0, @account.balance, 0.01
    assert_equal false, @account.extra.dig("binance", "stale_rate")
  end

  test "uses nearest rate and sets stale flag when exact rate missing" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR",
                         date: Date.current - 3, rate: 0.90)

    BinanceAccount::Processor.new(@ba).process

    @account.reload
    assert_equal "EUR", @account.currency
    assert_in_delta 900.0, @account.balance, 0.01
    assert_equal true, @account.extra.dig("binance", "stale_rate")
  end

  test "falls back to USD amount and sets stale flag when no rate available" do
    ExchangeRate.expects(:find_or_fetch_rate).returns(nil)

    BinanceAccount::Processor.new(@ba).process

    @account.reload
    assert_in_delta 1000.0, @account.balance, 0.01
    assert_equal true, @account.extra.dig("binance", "stale_rate")
  end

  test "clears stale flag on subsequent sync when exact rate found" do
    @account.update!(extra: { "binance" => { "stale_rate" => true } })
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR",
                         date: Date.current, rate: 0.92)

    BinanceAccount::Processor.new(@ba).process

    @account.reload
    assert_equal false, @account.extra.dig("binance", "stale_rate")
  end

  test "does not convert when family uses USD" do
    @family.update!(currency: "USD")

    BinanceAccount::Processor.new(@ba).process

    @account.reload
    assert_equal "USD", @account.currency
    assert_in_delta 1000.0, @account.balance, 0.01
  end
end
