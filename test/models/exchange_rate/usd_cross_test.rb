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

    rates = ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2)

    assert_equal [ @day1, @day2 ], rates.map(&:date)
    assert_equal [ 0.16, 0.176 ], rates.map { |r| r.rate.to_f }
    assert_equal [ "KZT", "RUB" ], [ rates.first.from, rates.first.to ]
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

  test "is empty when the first leg fails, without fetching the second" do
    @provider.expects(:fetch_exchange_rates).once.returns(provider_error_response(StandardError.new("no pair")))

    assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2)
  end

  private
    def rate(date, from, to, value)
      Provider::ExchangeRateConcept::Rate.new(date: date, from: from, to: to, rate: value)
    end
end
