require "test_helper"

class Provider::AccountData::ExchangeRateResolverTest < ActiveSupport::TestCase
  test "memoized values retain the actual market date used for each requested date" do
    requested = Date.new(2026, 9, 12)
    market_date = requested - 1
    ExchangeRate.expects(:find_or_fetch_rate).with(from: "USD", to: "CAD", date: requested).once
      .returns(OpenStruct.new(rate: BigDecimal("1.352345678"), date: market_date))
    resolver = Provider::AccountData::ExchangeRateResolver.new
    2.times do
      assert_equal({ rate: BigDecimal("1.352345678"), date: market_date.iso8601 }, resolver.call(from: "USD", to: "CAD", date: requested))
    end
  end

  test "a missing conversion stays missing while same-currency amounts use one" do
    date = Date.current
    ExchangeRate.expects(:find_or_fetch_rate).with(from: "USD", to: "CAD", date: date).once.returns(nil)
    resolver = Provider::AccountData::ExchangeRateResolver.new
    2.times { assert_nil resolver.call(from: "USD", to: "CAD", date: date) }
    assert_equal({ rate: BigDecimal("1"), date: date.iso8601 }, resolver.call(from: "USD", to: "USD", date: date))
  end

  test "nonexact and future-dated conversions cannot enter captured financial evidence" do
    date = Date.current
    ExchangeRate.expects(:find_or_fetch_rate).returns(OpenStruct.new(rate: 1.2, date: date))
    assert_raises(Provider::AccountData::InvalidResponse) do
      Provider::AccountData::ExchangeRateResolver.new.call(from: "USD", to: "CAD", date: date)
    end
    ExchangeRate.expects(:find_or_fetch_rate).returns(OpenStruct.new(rate: BigDecimal("1.2"), date: date + 1))
    assert_raises(Provider::AccountData::InvalidResponse) do
      Provider::AccountData::ExchangeRateResolver.new.call(from: "USD", to: "CAD", date: date)
    end
  end
end
