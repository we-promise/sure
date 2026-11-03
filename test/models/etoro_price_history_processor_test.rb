require "test_helper"

class EtoroPriceHistoryProcessorTest < ActiveSupport::TestCase
  setup do
    travel_to Time.utc(2026, 10, 24, 12)

    @etoro_account = etoro_accounts(:main_account)
    @account = families(:dylan_family).accounts.create!(name: "eToro", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new)
    @etoro_account.ensure_account_provider!(@account)
    @etoro_account.reload
    @acme = Security.create!(ticker: "ACME", name: "Acme", exchange_operating_mic: "XNAS", offline: true)
    @london = Security.create!(ticker: "LONX", name: "London Example", exchange_operating_mic: "XLON", offline: true)
    @processor = EtoroAccount::PriceHistoryProcessor.new(@etoro_account)
    ExchangeRate.stubs(:provider).returns(nil)
  end

  test "stores the closes it is given, and the same closes again change nothing" do
    closes = { Date.new(2026, 10, 22) => BigDecimal("101.5"), Date.new(2026, 10, 23) => BigDecimal("102") }

    2.times { assert_equal 2, @processor.process(@acme, currency: "USD", closes: closes).written }

    assert_equal [
      [ Date.new(2026, 10, 22), BigDecimal("101.5"), "USD", false ],
      [ Date.new(2026, 10, 23), BigDecimal("102"), "USD", false ]
    ], @acme.prices.order(:date).pluck(:date, :price, :currency, :provisional)
  end

  test "a restatement overwrites the days given and drops the security's prices in other currencies" do
    @acme.update!(offline_reason: EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON)
    Security::Price.create!(security: @acme, date: Date.new(2026, 10, 22), price: 203, currency: "USD")
    Security::Price.create!(security: @acme, date: Date.new(2026, 10, 21), price: 20000, currency: "GBX")

    @processor.process(@acme, currency: "USD", closes: { Date.new(2026, 10, 22) => BigDecimal("101.5") }, replace: true)

    assert_equal [ [ Date.new(2026, 10, 22), BigDecimal("101.5"), "USD" ] ], @acme.prices.pluck(:date, :price, :currency)
  end

  test "a restatement in a currency it can store nothing in keeps the prices in the one before" do
    @acme.update!(offline_reason: EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON)
    Security::Price.create!(security: @acme, date: Date.new(2026, 10, 22), price: 203, currency: "USD")

    result = @processor.process(@acme, currency: "HKD", closes: { Date.new(2026, 10, 22) => BigDecimal("1580") }, replace: true)

    assert_equal [ 0, 1 ], [ result.written, result.missing_rates ]
    assert_equal [ [ Date.new(2026, 10, 22), BigDecimal("203"), "USD" ] ], @acme.prices.pluck(:date, :price, :currency)
  end

  test "a foreign price is stored only on days an exchange rate converts it on" do
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: Date.new(2026, 10, 21), rate: 1.33)
    closes = { Date.new(2026, 10, 15) => BigDecimal("12.5"), Date.new(2026, 10, 16) => BigDecimal("12.6"), Date.new(2026, 10, 23) => BigDecimal("12.8") }

    result = @processor.process(@london, currency: "GBP", closes: closes)

    assert_equal [ Date.new(2026, 10, 23) ], @london.prices.pluck(:date), "a rate a couple of days old still converts"
    assert_equal [ 1, 2 ], [ result.written, result.missing_rates ]
  end

  test "stores nothing in a currency it has no exchange rates for" do
    result = @processor.process(@london, currency: "HKD", closes: { Date.new(2026, 10, 23) => BigDecimal("26.8") })

    assert_empty @london.prices
    assert_equal 1, result.missing_rates
  end

  test "imports the exchange rates it lacks, once a run for each currency" do
    ExchangeRate.expects(:import_provider_rates)
      .with(from: "GBP", to: "USD", start_date: Date.new(2026, 10, 19), end_date: Date.current)
      .once
    other = Security.create!(ticker: "LONY", exchange_operating_mic: "XLON", offline: true)

    @processor.process(@london, currency: "GBP", closes: { Date.new(2026, 10, 19) => BigDecimal("12.5") })
    @processor.process(other, currency: "GBP", closes: { Date.new(2026, 10, 20) => BigDecimal("8.5") })
  end

  test "asks for no exchange rates the account's currency or stored ones cover" do
    (Date.new(2026, 10, 19)..Date.new(2026, 10, 23)).each { |day| ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: day, rate: 1.33) }
    ExchangeRate.expects(:import_provider_rates).never

    @processor.process(@acme, currency: "USD", closes: { Date.new(2026, 10, 19) => BigDecimal("100") })
    result = @processor.process(@london, currency: "GBP", closes: { Date.new(2026, 10, 19) => BigDecimal("12.5"), Date.new(2026, 10, 23) => BigDecimal("12.8") })

    assert_equal 2, result.written
  end

  test "eToro's prices go only on offline securities no price provider covers" do
    priceable = ->(attributes) { EtoroAccount::PriceHistoryProcessor.priceable?(Security.new({ ticker: "ANY" }.merge(attributes))) }

    assert priceable.call(offline: true)
    assert priceable.call(offline: true, offline_reason: "health_check_failed")
    assert priceable.call(offline: true, offline_reason: EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON)
    assert_not priceable.call(offline: false, offline_reason: EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON), "a price provider's check found it"
    assert_not priceable.call(offline: false)
    assert_not priceable.call(offline: true, price_provider: "yahoo_finance")
    assert_not priceable.call(offline: true, offline_reason: "provider_disabled")
    assert_not priceable.call(offline: true, offline_reason: "trade_republic_isin")
    assert_not priceable.call(offline: true, kind: "cash")
  end

  test "a security a price provider stopped finding keeps the provider's prices and gets none from eToro" do
    failed = Security.create!(ticker: "FAIL", exchange_operating_mic: "XNAS", offline: true, offline_reason: "health_check_failed")
    Security::Price.create!(security: failed, date: Date.new(2026, 9, 1), price: 50, currency: "EUR")
    Security::Price.create!(security: failed, date: Date.new(2026, 10, 22), price: 90, currency: "USD")
    closes = { Date.new(2026, 10, 22) => BigDecimal("101.5"), Date.new(2026, 10, 23) => BigDecimal("102") }

    assert_not EtoroAccount::PriceHistoryProcessor.priceable?(failed)
    assert_nil @processor.process(failed, currency: "USD", closes: closes, replace: true)

    assert_equal [ [ Date.new(2026, 9, 1), BigDecimal("50"), "EUR" ], [ Date.new(2026, 10, 22), BigDecimal("90"), "USD" ] ],
      failed.prices.order(:date).pluck(:date, :price, :currency)
    assert_equal "health_check_failed", failed.reload.offline_reason
  end

  test "writing prices claims the security, and writing none leaves it to Sure" do
    @processor.process(@london, currency: "HKD", closes: { Date.new(2026, 10, 23) => BigDecimal("26.8") })
    @processor.process(@acme, currency: "USD", closes: { Date.new(2026, 10, 23) => BigDecimal("102") })

    assert_nil @london.reload.offline_reason
    assert_equal EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON, @acme.reload.offline_reason
  end

  test "hands back the securities eToro no longer prices without the prices it stored" do
    priced = Security.create!(ticker: "PRCD", offline: true, offline_reason: EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON)
    Security::Price.create!(security: priced, date: Date.new(2026, 5, 29), price: 9, currency: "USD")
    Security::Price.create!(security: priced, date: Date.new(2026, 10, 23), price: 10, currency: "USD")
    disabled = Security.create!(ticker: "DSBL", offline: true, offline_reason: "provider_disabled")

    EtoroAccount::PriceHistoryProcessor.release([
      { "security_id" => priced.id, "currency" => "USD", "written_from" => "2026-06-01" },
      { "security_id" => disabled.id }
    ])

    assert_equal [ true, nil ], [ priced.reload.offline?, priced.offline_reason ]
    assert_equal [ Date.new(2026, 5, 29) ], priced.prices.pluck(:date), "a price from before eToro's stays"
    assert_equal "provider_disabled", disabled.reload.offline_reason
  end

  test "a release deletes nothing in a currency eToro stored no price in" do
    Security::Price.create!(security: @london, date: Date.new(2025, 1, 6), price: 9.99, currency: "GBP")

    EtoroAccount::PriceHistoryProcessor.release([ { "security_id" => @london.id, "currency" => "GBP" } ])

    assert_equal 1, @london.prices.count
  end

  test "a release syncs again the accounts valued at the prices it deletes, apart from the one syncing" do
    priced = Security.create!(ticker: "PRCD", offline: true, offline_reason: EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON)
    Security::Price.create!(security: priced, date: Date.new(2026, 10, 23), price: 10, currency: "USD")
    holder = accounts(:investment)
    [ holder, @account ].each { |account| account.holdings.create!(security: priced, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD") }

    assert_difference -> { holder.syncs.count } => 1, -> { @account.syncs.count } => 0 do
      EtoroAccount::PriceHistoryProcessor.release([ { "security_id" => priced.id, "currency" => "USD", "written_from" => "2026-06-01" } ], syncing: @account)
    end
  end

  test "writes nothing on a security a health check brought online or a user gave a provider since the sync began" do
    found = Security.create!(ticker: "FOND", offline: false, offline_reason: EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON)
    chosen = Security.create!(ticker: "CHSN", offline: true, price_provider: "yahoo_finance")
    Security::Price.create!(security: chosen, date: Date.new(2026, 10, 22), price: 9, currency: "GBP")
    closes = { Date.new(2026, 10, 23) => BigDecimal("102") }

    assert_nil @processor.process(found, currency: "USD", closes: closes)
    assert_nil @processor.process(chosen, currency: "USD", closes: closes, replace: true)

    assert_empty found.prices
    assert_equal [ "GBP" ], chosen.prices.pluck(:currency)
    assert_equal [ false, EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON ], [ found.reload.offline?, found.offline_reason ]
    assert_nil chosen.reload.offline_reason
  end
end
