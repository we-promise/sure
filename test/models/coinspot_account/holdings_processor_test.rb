# frozen_string_literal: true

require "test_helper"

class CoinspotAccount::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "AUD")
    @item = CoinspotItem.create!(family: @family, name: "CoinSpot", api_key: "k", api_secret: "s")
    @coinspot_account = @item.coinspot_accounts.create!(
      name: "CoinSpot",
      account_id: "combined",
      account_type: "combined",
      currency: "AUD",
      current_balance: 0,
      raw_payload: { "assets" => [] }
    )
    @account = Account.create!(
      family: @family,
      name: "CoinSpot",
      balance: 0,
      currency: "AUD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    @account_provider = AccountProvider.create!(account: @account, provider: @coinspot_account)
    @security = Security.create!(ticker: "CRYPTO:BTC", name: "BTC", exchange_operating_mic: "XCSO", offline: true)
  end

  test "marks provider holdings absent from latest snapshot as zero on current date" do
    @account.holdings.create!(
      security: @security,
      provider_security: @security,
      qty: 0.5,
      amount: 50_000,
      currency: "AUD",
      date: Date.current - 1.day,
      price: 100_000,
      account_provider_id: @account_provider.id,
      external_id: "coinspot_BTC_spot_#{Date.current - 1.day}"
    )

    assert_difference -> { @account.holdings.where(account_provider_id: @account_provider.id).count }, 1 do
      CoinspotAccount::HoldingsProcessor.new(@coinspot_account).process
    end

    zero_holding = @account.holdings.find_by!(
      account_provider_id: @account_provider.id,
      security: @security,
      date: Date.current
    )
    assert_equal 0.to_d, zero_holding.qty
    assert_equal 0.to_d, zero_holding.amount
    assert_empty @account.current_holdings
  end

  test "preserves an eight-decimal asset quantity from the balance snapshot" do
    @coinspot_account.update!(raw_payload: {
      "assets" => [
        {
          "symbol" => "BTC",
          "balance" => "0.00014884",
          "amount_aud" => "14.884",
          "price_aud" => "100000",
          "source" => "spot"
        }
      ]
    })
    CoinspotAccount::SecurityResolver.stubs(:resolve).with("BTC").returns(@security)

    result = CoinspotAccount::HoldingsProcessor.new(@coinspot_account).process

    assert_equal true, result[:success], result.inspect
    holding = @account.holdings.find_by!(security: @security, date: Date.current)
    assert_equal BigDecimal("0.00014884"), holding.qty
    assert_equal BigDecimal("14.884"), holding.amount
  end

  test "returns a failure and captures diagnostics when a holding cannot be imported" do
    @coinspot_account.update!(raw_payload: {
      "assets" => [
        { "symbol" => "BTC", "balance" => "0.1", "amount_aud" => "1000", "price_aud" => "100000" }
      ]
    })
    CoinspotAccount::SecurityResolver.stubs(:resolve).with("BTC").returns(@security)
    Account::ProviderImportAdapter.any_instance.stubs(:import_holding).raises(StandardError, "holding import failed")
    DebugLogEntry.expects(:capture).with(has_entries(
      category: "provider_sync_error",
      level: "error",
      provider_key: "coinspot",
      family: @family
    )).once

    result = CoinspotAccount::HoldingsProcessor.new(@coinspot_account).process

    assert_equal false, result[:success]
    assert_equal "holding", result[:failures].first[:kind]
  end

  test "does not import a holding when its non-AUD valuation cannot be converted" do
    @family.update!(currency: "USD")
    @coinspot_account.update!(raw_payload: {
      "assets" => [
        { "symbol" => "BTC", "balance" => "0.1", "amount_aud" => "1000", "price_aud" => "100000" }
      ]
    })
    CoinspotAccount::SecurityResolver.stubs(:resolve).with("BTC").returns(@security)
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    result = CoinspotAccount::HoldingsProcessor.new(@coinspot_account).process

    assert_equal false, result[:success]
    assert_empty @account.holdings.where(account_provider_id: @account_provider.id)
  end
end
