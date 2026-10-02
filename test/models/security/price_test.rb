require "test_helper"
require "ostruct"

class Security::PriceTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @provider = mock
    @security = securities(:aapl)
    @security.stubs(:price_data_provider).returns(@provider)
  end

  test "finds single security price in DB" do
    @provider.expects(:fetch_security_price).never
    price = security_prices(:one)

    assert_equal price, @security.find_or_fetch_price(date: price.date)
  end

  test "caches prices from provider to DB" do
    price_date = 10.days.ago.to_date

    expected_price = Security::Price.new(
      security: @security,
      date: price_date,
      price: 314.34,
      currency: "USD"
    )

    expect_provider_price(security: @security, price: expected_price, date: price_date)

    assert_difference "Security::Price.count", 1 do
      fetched_price = @security.find_or_fetch_price(date: price_date, cache: true)
      assert_equal expected_price.price, fetched_price.price
    end
  end

  test "reuses a price inserted while the provider request is in flight" do
    price_date = 30.years.ago.to_date
    existing_price = Security::Price.create!(
      security: @security,
      date: price_date,
      price: 300,
      currency: "USD"
    )
    provider_price = Security::Price.new(
      security: @security,
      date: price_date,
      price: 314.34,
      currency: "USD"
    )

    # Simulate the initial lookup losing a race to another price insert.
    valid_prices = mock("valid_prices")
    @security.prices.expects(:with_known_currency).returns(valid_prices)
    valid_prices.expects(:find_by).with(date: price_date).returns(nil)
    expect_provider_price(security: @security, price: provider_price, date: price_date)

    assert_no_difference "Security::Price.count" do
      fetched_price = @security.find_or_fetch_price(date: price_date, cache: true)
      assert_equal provider_price.price, fetched_price.price
    end
    assert_equal 300, existing_price.reload.price
  end

  test "returns nil if no price found in DB or from provider" do
    security = securities(:aapl)
    Security::Price.delete_all # Clear any existing prices

    with_provider_response = provider_error_response(StandardError.new("Test error"))

    @provider.expects(:fetch_security_price)
             .with(symbol: security.ticker, exchange_operating_mic: security.exchange_operating_mic, date: Date.current)
             .returns(with_provider_response)

    assert_not @security.find_or_fetch_price(date: Date.current)
  end

  test "rejects an unsupported price currency" do
    price = Security::Price.new(security: @security, date: Date.current, price: 100, currency: "INVALID")

    assert_not price.valid?
    assert price.errors[:currency].any?
  end

  test "a validated edit settles a generated retry fallback" do
    @security.prices.where(date: Date.current).delete_all
    price = @security.prices.create!(date: Date.current, price: 100, currency: "USD",
      provisional: true, currency_retry_required: true)

    price.update!(price: 120)

    assert_not price.reload.currency_retry_required?
    assert_not price.provisional?
    @provider.expects(:fetch_security_prices).never
    result = Security::Price::Importer.new(security: @security, security_provider: @provider,
      start_date: Date.current, end_date: Date.current).import_provider_prices
    assert_equal 0, result
    assert_equal 120, price.reload.price
  end

  test "recovery is scoped to the same security and quote date" do
    date = 20.days.ago.to_date
    bad = @security.prices.create!(date: date, price: 100, currency: "USD")
    bad.update_column(:currency, "")
    other = securities(:msft)
    other.prices.create!(date: date, price: 100, currency: "USD")
    assert_includes Security::Price.with_unrecovered_currency, bad

    replacement = @security.prices.create!(date: date, price: 105, currency: "USD", currency_retry_required: true)
    assert_includes Security::Price.with_unrecovered_currency, bad
    replacement.update!(currency_retry_required: false)
    assert_not_includes Security::Price.with_unrecovered_currency, bad
  end

  test "normalizes a supported price currency before saving" do
    price = Security::Price.create!(
      security: @security, date: 10.days.ago.to_date, price: 100, currency: " usd "
    )

    assert_equal "USD", price.currency
  end

  test "updating a legacy lowercase price does not collide with an uppercase price" do
    price_date = 11.days.ago.to_date
    legacy = Security::Price.create!(security: @security, date: price_date, price: 100, currency: "USD")
    legacy.update_column(:currency, "usd")
    Security::Price.create!(security: @security, date: price_date, price: 101, currency: "USD")

    legacy.update!(price: 102)

    assert_equal "usd", legacy.reload[:currency]
    assert_equal "USD", legacy.currency
    assert_equal 102, legacy.price
  end

  test "ignores a legacy blank-currency price and fetches a valid replacement" do
    price_date = 10.days.ago.to_date
    bad_price = Security::Price.create!(security: @security, date: price_date, price: 100, currency: "USD")
    bad_price.update_column(:currency, "")
    expect_provider_price(
      security: @security,
      price: Security::Price.new(security: @security, date: price_date, price: 105, currency: "USD"),
      date: price_date
    )

    replacement = @security.find_or_fetch_price(date: price_date)

    assert_equal "USD", replacement.currency
    assert_equal 105, replacement.price
  end

  test "does not return or cache a provider price with an unknown currency" do
    price_date = 10.days.ago.to_date
    expect_provider_price(
      security: @security,
      price: Security::Price.new(security: @security, date: price_date, price: 105, currency: ""),
      date: price_date
    )

    assert_difference "DebugLogEntry.count", 1 do
      assert_no_difference "Security::Price.count" do
        assert_nil @security.find_or_fetch_price(date: price_date)
      end
    end
  end

  test "current price accepts a normalized provider currency" do
    @security.prices.where(date: Date.current).delete_all
    expect_provider_price(
      security: @security,
      price: Security::Price.new(security: @security, date: Date.current, price: 105, currency: " usd "),
      date: Date.current
    )

    assert_equal "USD", @security.current_price.currency.iso_code
  end

  private
    def expect_provider_price(security:, price:, date:)
      @provider.expects(:fetch_security_price)
               .with(symbol: security.ticker, exchange_operating_mic: security.exchange_operating_mic, date: date)
               .returns(provider_success_response(price))
    end

    def expect_provider_prices(security:, prices:, start_date:, end_date:)
      @provider.expects(:fetch_security_prices)
               .with(security, start_date: start_date, end_date: end_date)
               .returns(provider_success_response(prices))
    end
end
