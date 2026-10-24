require "test_helper"

class ExchangeRate::UsdCrossTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @provider = mock
    @day1 = Date.new(2026, 10, 19)
    @day2 = @day1 + 1
  end

  test "multiplies the USD legs, carrying the latest USD rate over a gap" do
    @provider.expects(:fetch_exchange_rates).with(from: "KZT", to: "USD", start_date: @day1, end_date: @day2)
             .returns(provider_success_response([ rate(@day2, "KZT", "USD", 0.0022), rate(@day1, "KZT", "USD", 0.002) ]))
    @provider.expects(:fetch_exchange_rates).with(from: "USD", to: "RUB", start_date: @day1, end_date: @day2)
             .returns(provider_success_response([ rate(@day1, "USD", "RUB", 80) ]))

    rates = ExchangeRate::UsdCross.new(@provider)
      .rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2, error: StandardError.new("no KZT/RUB"))

    assert_equal [ @day1, @day2 ], rates.map(&:date)
    assert_equal [ 0.16, 0.176 ], rates.map { |r| r.rate.to_f }
    assert_equal [ "KZT", "RUB" ], [ rates.first.from, rates.first.to ]

    entry = DebugLogEntry.where(category: "exchange_rates", level: "info").recent.first
    assert_equal "ExchangeRate::UsdCross", entry.source
    assert_equal "no KZT/RUB", entry.metadata["direct_error"]
  end

  test "skips a product that rounds to a zero rate" do
    @provider.stubs(:fetch_exchange_rates).with(from: "AAA", to: "USD", start_date: @day1, end_date: @day1)
             .returns(provider_success_response([ rate(@day1, "AAA", "USD", 0.0000001) ]))
    @provider.stubs(:fetch_exchange_rates).with(from: "USD", to: "BBB", start_date: @day1, end_date: @day1)
             .returns(provider_success_response([ rate(@day1, "USD", "BBB", 0.000001) ]))

    assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "AAA", to: "BBB", start_date: @day1, end_date: @day1)
  end

  test "is empty without asking the provider when it is rate limiting or rejecting requests" do
    @provider.expects(:fetch_exchange_rates).never
    cross = ExchangeRate::UsdCross.new(@provider)

    [ Provider::TwelveData::RateLimitError.new("slow down"), Provider::YahooFinance::AuthenticationError.new("no crumb") ].each do |error|
      assert_empty cross.rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2, error: error)
    end
  end

  test "skips days before the first USD rate" do
    @provider.stubs(:fetch_exchange_rates).with(from: "KZT", to: "USD", start_date: @day1, end_date: @day2)
             .returns(provider_success_response([ rate(@day1, "KZT", "USD", 0.002), rate(@day2, "KZT", "USD", 0.0022) ]))
    @provider.stubs(:fetch_exchange_rates).with(from: "USD", to: "RUB", start_date: @day1, end_date: @day2)
             .returns(provider_success_response([ rate(@day2, "USD", "RUB", 80) ]))

    rates = ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2)

    assert_equal [ @day2 ], rates.map(&:date)
  end

  test "is empty without asking the provider when a side is USD" do
    @provider.expects(:fetch_exchange_rates).never

    assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "USD", to: "RUB", start_date: @day1, end_date: @day2)
    assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "RUB", to: "USD", start_date: @day1, end_date: @day2)
  end

  test "is empty without asking the provider for a pair it has quoted before" do
    ExchangeRatePair.record_direct_quote(from: "KZT", to: "RUB")
    @provider.expects(:fetch_exchange_rates).never

    assert_empty ExchangeRate::UsdCross.new(@provider)
      .rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2, error: StandardError.new("timeout"))
  end

  test "is empty when the first leg fails, without fetching the second, and logs the leg" do
    @provider.expects(:fetch_exchange_rates).once.returns(provider_error_response(StandardError.new("no pair")))

    assert_difference -> { DebugLogEntry.where(category: "exchange_rates", level: "warn").count }, 1 do
      assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2)
    end

    metadata = DebugLogEntry.where(category: "exchange_rates").recent.first.metadata
    assert_equal({ "from" => "KZT", "to" => "USD", "error" => "no pair" }, metadata.slice("from", "to", "error"))
  end

  private
    def rate(date, from, to, value)
      Provider::ExchangeRateConcept::Rate.new(date: date, from: from, to: to, rate: value)
    end
end
