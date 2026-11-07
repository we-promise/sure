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

  test "replaces a priced holding with a zero-valued one when the asset loses its AUD price" do
    pay = Security.create!(ticker: "CRYPTO:PAY", name: "PAY", exchange_operating_mic: "XCSO", offline: true)
    @account.holdings.create!(
      security: pay,
      provider_security: pay,
      qty: 12.5,
      amount: 25,
      currency: "AUD",
      date: Date.current - 1.day,
      price: 2,
      account_provider_id: @account_provider.id,
      external_id: "coinspot_PAY_spot_#{Date.current - 1.day}"
    )
    @coinspot_account.update!(raw_payload: {
      "assets" => [ { "symbol" => "PAY", "balance" => "12.5", "amount_aud" => nil, "price_aud" => nil, "source" => "spot" } ]
    })
    CoinspotAccount::SecurityResolver.stubs(:resolve).with("PAY").returns(pay)

    result = CoinspotAccount::HoldingsProcessor.new(@coinspot_account).process

    assert_equal true, result[:success], result.inspect
    holding = @account.current_holdings.find_by!(security: pay)
    assert_equal Date.current, holding.date
    assert_equal BigDecimal("12.5"), holding.qty
    assert_equal 0.to_d, holding.amount
    assert_equal 0.to_d, holding.price
  end

  test "overwrites a same-day priced holding when the asset loses its AUD price" do
    priced = { "symbol" => "BTC", "balance" => "0.5", "amount_aud" => "50000", "price_aud" => "100000", "source" => "spot" }
    @coinspot_account.update!(raw_payload: { "assets" => [ priced ] })
    CoinspotAccount::SecurityResolver.stubs(:resolve).with("BTC").returns(@security)
    CoinspotAccount::HoldingsProcessor.new(@coinspot_account).process

    @coinspot_account.update!(raw_payload: { "assets" => [ priced.merge("amount_aud" => nil, "price_aud" => nil) ] })
    result = CoinspotAccount::HoldingsProcessor.new(@coinspot_account).process

    assert_equal true, result[:success], result.inspect
    holdings = @account.holdings.where(security: @security, date: Date.current)
    assert_equal 1, holdings.count
    assert_equal 0.to_d, holdings.first.amount
    assert_equal BigDecimal("0.5"), holdings.first.qty
  end

  test "keeps a remapped holding whose provider security is still in the snapshot" do
    chosen = Security.create!(ticker: "CRYPTO:XBT", name: "XBT", exchange_operating_mic: "XCSO", offline: true)
    @account.holdings.create!(
      security: chosen,
      provider_security: @security,
      security_locked: true,
      qty: 0.5,
      amount: 50_000,
      currency: "AUD",
      date: Date.current - 1.day,
      price: 100_000,
      account_provider_id: @account_provider.id,
      external_id: "coinspot_BTC_spot_#{Date.current - 1.day}"
    )
    @coinspot_account.update!(raw_payload: {
      "assets" => [ { "symbol" => "BTC", "balance" => "0.5", "amount_aud" => nil, "price_aud" => nil, "source" => "spot" } ]
    })
    CoinspotAccount::SecurityResolver.stubs(:resolve).with("BTC").returns(@security)

    result = CoinspotAccount::HoldingsProcessor.new(@coinspot_account).process

    assert_equal true, result[:success], result.inspect
    today = @account.holdings.where(date: Date.current)
    assert_equal [ chosen.id ], today.pluck(:security_id)
    assert_equal BigDecimal("0.5"), today.first.qty
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

  # An unavailable snapshot is not an empty portfolio. `assets` missing used to
  # read as [], and the absent-holdings sweep then zeroed everything the
  # account held -- silent data loss on a failed fetch.
  test "does not zero holdings when the snapshot carries no assets array" do
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
    @coinspot_account.update!(raw_payload: { "status" => "error" })

    result = nil
    assert_no_difference -> { @account.holdings.where(account_provider_id: @account_provider.id).count } do
      result = CoinspotAccount::HoldingsProcessor.new(@coinspot_account).process
    end

    assert_equal false, result[:success]
    assert_equal 0.5.to_d, @account.holdings.where(account_provider_id: @account_provider.id).order(:date).last.qty
  end

  # Same guard, non-array shape: a payload whose `assets` is a Hash or String
  # is malformed, not empty. A count assertion alone cannot catch the
  # regression, because zeroing rewrites the row rather than removing it --
  # hence the explicit quantity assertion.
  test "does not zero holdings when assets is present but not an array" do
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
    @coinspot_account.update!(raw_payload: { "assets" => { "btc" => { "balance" => "0.5" } } })

    result = CoinspotAccount::HoldingsProcessor.new(@coinspot_account).process

    assert_equal false, result[:success]
    assert_equal 0.5.to_d, @account.holdings.where(account_provider_id: @account_provider.id).order(:date).last.qty
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
