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
    @security.prices.expects(:find_by).with(date: price_date).returns(nil)
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
