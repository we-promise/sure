# frozen_string_literal: true

require "test_helper"

class RevolutXAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")
    @item = @family.revolut_x_items.create!(name: "Revolut X", api_key: "a1" * 32)
  end

  test "imports crypto as holdings and fiat as cash" do
    account = import_and_link

    RevolutXAccount::Processor.new(@revolut_x_account).process

    holdings = account.holdings.where(date: Date.current).includes(:security).index_by { |holding| holding.security.ticker }
    assert_equal %w[CRYPTO:BTC CRYPTO:ETH], holdings.keys.sort
    assert_equal 1.35.to_d, holdings["CRYPTO:BTC"].qty
    assert_equal 42, holdings["CRYPTO:ETH"].qty
    assert_equal 120_000, holdings["CRYPTO:BTC"].price
    assert_equal "revolut_x_BTC_#{Date.current}", holdings["CRYPTO:BTC"].external_id

    account.reload
    holdings_value = holdings.values.sum(&:amount)
    assert_equal 5500.50.to_d, account.cash_balance
    assert_equal holdings_value + 5500.50.to_d, account.balance
    assert_equal "USD", account.currency
  end

  test "skips an asset nothing prices and reports it" do
    account = import_and_link(extra_balances: [ { "currency" => "DOGE", "available" => "5", "reserved" => "0", "total" => "5" } ])

    assert_difference -> { DebugLogEntry.where(provider_key: "revolut_x").count }, 1 do
      RevolutXAccount::Processor.new(@revolut_x_account).process
    end

    assert_not account.holdings.joins(:security).exists?(securities: { ticker: "CRYPTO:DOGE" })
    assert_match "DOGE", DebugLogEntry.where(provider_key: "revolut_x").last.message
  end

  test "a coin gone from a later same-day sync is no longer held" do
    account = import_and_link
    RevolutXAccount::Processor.new(@revolut_x_account).process

    reimport(payload("balances").reject { |balance| balance["currency"] == "ETH" })
    RevolutXAccount::Processor.new(@revolut_x_account).process

    assert_equal %w[CRYPTO:BTC], account.reload.current_holdings.map { |holding| holding.security.ticker }
  end

  test "selling all crypto leaves no current holdings" do
    account = import_and_link
    RevolutXAccount::Processor.new(@revolut_x_account).process
    account.holdings.update_all(date: 1.day.ago.to_date)

    reimport(payload("balances").select { |balance| balance["currency"] == "USD" })
    RevolutXAccount::Processor.new(@revolut_x_account).process

    assert_empty account.reload.current_holdings
    assert_equal account.cash_balance, account.balance
  end

  test "a held coin that loses its price is reported and no longer held" do
    account = import_and_link
    RevolutXAccount::Processor.new(@revolut_x_account).process

    @tickers["data"].reject! { |ticker| ticker["symbol"].start_with?("ETH/") }
    reimport(payload("balances"))
    assert_difference -> { DebugLogEntry.where(provider_key: "revolut_x").count }, 1 do
      RevolutXAccount::Processor.new(@revolut_x_account).process
    end

    assert_match "ETH", DebugLogEntry.where(provider_key: "revolut_x").last.message
    account.reload
    assert_equal %w[CRYPTO:BTC], account.current_holdings.map { |holding| holding.security.ticker }
    assert_equal account.current_holdings.sum(&:amount) + account.cash_balance, account.balance
  end

  test "reports fiat cash that has no USD rate" do
    @family.update!(currency: "EUR")
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 0.9)
    import_and_link(extra_balances: [ { "currency" => "GBP", "available" => "100", "reserved" => "0", "total" => "100" } ])

    assert_difference -> { DebugLogEntry.where(provider_key: "revolut_x").count }, 1 do
      RevolutXAccount::Processor.new(@revolut_x_account).process
    end
    assert_match "GBP", DebugLogEntry.where(provider_key: "revolut_x").last.message
  end

  test "imports the stored transaction history" do
    account = import_and_link
    @revolut_x_account.update!(raw_transactions_payload: {
      "transactions" => JSON.parse(file_fixture("revolut_x/transactions.json").read)["data"].index_by { |row| row["id"] }
    })
    Security.any_instance.stubs(:import_provider_prices).returns(0)

    RevolutXAccount::Processor.new(@revolut_x_account).process

    assert_equal 3, account.entries.where(source: "revolut_x").count
  end

  private

    def reimport(balances)
      @provider.stubs(:get_balances).returns(balances)
      @provider.stubs(:get_tickers).returns(@tickers)
      RevolutXItem::Importer.new(@item, revolut_x_provider: @provider).import
      @revolut_x_account.reload
    end

    def import_and_link(extra_balances: [])
      @provider = provider = mock
      provider.stubs(:get_balances).returns(payload("balances") + extra_balances)
      provider.stubs(:get_sub_accounts).returns(payload("sub_accounts"))
      provider.stubs(:get_currencies).returns(payload("currencies"))
      @tickers = tickers = payload("tickers")
      tickers["data"] << { "symbol" => "ETH/USD", "mid" => "3000.00" }
      provider.stubs(:get_tickers).returns(tickers)
      provider.stubs(:get_transactions).returns({ "data" => [], "metadata" => {} })
      RevolutXItem::Importer.new(@item, revolut_x_provider: provider).import

      @revolut_x_account = @item.revolut_x_accounts.sole
      account = Account.create_from_revolut_x_account(@revolut_x_account)
      AccountProvider.create!(account: account, provider: @revolut_x_account)
      @revolut_x_account.reload
      account
    end

    def payload(name)
      JSON.parse(file_fixture("revolut_x/#{name}.json").read)
    end
end
