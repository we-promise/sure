# frozen_string_literal: true

require "test_helper"

class KrakenAccount::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")
    @item = KrakenItem.create!(
      family: @family,
      name: "Kraken",
      api_key: "k",
      api_secret: "s"
    )
    @kraken_account = @item.kraken_accounts.create!(
      name: "Kraken",
      account_id: "combined",
      account_type: "combined",
      currency: "USD",
      current_balance: 30_000,
      raw_payload: {
        "assets" => [
          { "symbol" => "BTC", "price_symbol" => "BTC", "balance" => "0.5", "price_usd" => "60000.0", "source" => "spot" }
        ]
      }
    )
    @account = Account.create!(
      family: @family,
      name: "Kraken",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    @account_provider = AccountProvider.create!(account: @account, provider: @kraken_account)
    @security = Security.create!(ticker: "CRYPTO:BTC", name: "BTC", exchange_operating_mic: "XKRA", offline: true)
    KrakenAccount::SecurityResolver.stubs(:resolve).returns(@security)
  end

  test "imports holdings with account_provider_id" do
    import_adapter = mock
    import_adapter.expects(:import_holding).with(
      has_entries(
        security: @security,
        quantity: 0.5.to_d,
        amount: 30_000.to_d,
        currency: "USD",
        price: 60_000.to_d,
        external_id: "kraken_BTC_spot_#{Date.current}",
        account_provider_id: @account_provider.id,
        source: "kraken"
      )
    )
    Account::ProviderImportAdapter.stubs(:new).returns(import_adapter)

    KrakenAccount::HoldingsProcessor.new(@kraken_account).process
  end

  test "does not overwrite a different provider holding with the same security/date/currency" do
    binance_item = BinanceItem.create!(family: @family, name: "Binance", api_key: "b", api_secret: "s")
    binance_account = binance_item.binance_accounts.create!(name: "Binance", account_type: "combined", currency: "USD")
    binance_provider = AccountProvider.create!(account: @account, provider: binance_account)
    existing = @account.holdings.create!(
      security: @security,
      qty: 0.25,
      amount: 15_000,
      currency: "USD",
      date: Date.current,
      price: 60_000,
      account_provider_id: binance_provider.id
    )

    assert_no_difference -> { @account.holdings.count } do
      KrakenAccount::HoldingsProcessor.new(@kraken_account).process
    end

    assert_equal binance_provider.id, existing.reload.account_provider_id
    assert_nil existing.external_id
    assert_nil @account.holdings.find_by(external_id: "kraken_BTC_spot_#{Date.current}")
  end

  test "does not log raw asset payloads when holding import fails" do
    raw_asset = {
      "symbol" => "BTC",
      "price_symbol" => "BTC",
      "balance" => "0.5",
      "price_usd" => "60000.0",
      "source" => "spot",
      "account_balance_detail" => "sensitive payload"
    }
    @kraken_account.update!(raw_payload: { "assets" => [ raw_asset ] })
    failing_adapter = mock
    failing_adapter.stubs(:import_holding).raises(StandardError, "boom")
    Account::ProviderImportAdapter.stubs(:new).returns(failing_adapter)

    Rails.logger.expects(:error)
      .with("KrakenAccount::HoldingsProcessor - failed asset symbol=BTC: boom")

    KrakenAccount::HoldingsProcessor.new(@kraken_account).process
  end
end
