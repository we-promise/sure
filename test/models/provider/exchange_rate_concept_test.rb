require "test_helper"

class Provider::ExchangeRateConceptTest < ActiveSupport::TestCase
  # Answers with whatever rates it is given, like a provider whose API
  # occasionally publishes a zero or missing rate, or fails when given an error.
  class StubProvider < Provider
    include Provider::ExchangeRateConcept

    def initialize(rates, error: nil)
      @rates = rates
      @error = error
    end

    def fetch_exchange_rate(from:, to:, date:)
      with_provider_response do
        raise @error if @error

        Rate.new(date:, from:, to:, rate: @rates.first)
      end
    end

    def fetch_exchange_rates(from:, to:, start_date:, end_date:)
      with_provider_response do
        raise @error if @error

        @rates.each_with_index.map { |rate, index| Rate.new(date: start_date + index, from:, to:, rate:) }
      end
    end
  end

  test "rejects a single rate that cannot convert an amount" do
    [ 0, "0.0", -1.5, nil, Float::NAN, Float::INFINITY ].each do |value|
      response = StubProvider.new([ value ]).fetch_exchange_rate(from: "CHF", to: "CNY", date: Date.current)

      assert_not response.success?, "expected a rate of #{value.inspect} to fail the lookup"
      assert_nil response.data
      assert_kind_of Provider::Error, response.error
    end
  end

  test "passes a valid single rate through unchanged" do
    response = StubProvider.new([ "8.0723" ]).fetch_exchange_rate(from: "CHF", to: "CNY", date: Date.current)

    assert response.success?
    assert_equal "8.0723", response.data.rate
  end

  test "drops invalid rates from a series and keeps the valid ones" do
    start_date = 3.days.ago.to_date

    response = StubProvider.new([ 8.07, 0, nil, 8.08 ])
                           .fetch_exchange_rates(from: "CHF", to: "CNY", start_date: start_date, end_date: Date.current)

    assert response.success?
    assert_equal [ start_date, start_date + 3 ], response.data.map(&:date)
    assert_equal [ 8.07, 8.08 ], response.data.map(&:rate)
  end

  test "records invalid rates in the debug log" do
    assert_difference -> { DebugLogEntry.where(category: "exchange_rates", level: "warn").count }, 1 do
      StubProvider.new([ 8.07, 0 ]).fetch_exchange_rates(from: "CHF", to: "CNY", start_date: 1.day.ago.to_date, end_date: Date.current)
    end

    entry = DebugLogEntry.where(category: "exchange_rates").recent.first
    assert_equal "CHF", entry.metadata["from"]
    assert_equal "CNY", entry.metadata["to"]
    assert_equal [ Date.current.to_s ], entry.metadata["rates"].map { |rate| rate["date"] }
  end

  test "passes failed lookups through unchanged" do
    provider = StubProvider.new([], error: StandardError.new("timeout"))

    [
      provider.fetch_exchange_rate(from: "CHF", to: "CNY", date: Date.current),
      provider.fetch_exchange_rates(from: "CHF", to: "CNY", start_date: Date.current, end_date: Date.current)
    ].each do |response|
      assert_not response.success?
      assert_equal "timeout", response.error.message
    end
  end

  # A provider added to the registry is covered without extra work, as long as
  # it includes the concept.
  test "every registered exchange rate provider validates its rates" do
    Provider::Registry.for_concept(:exchange_rates).provider_keys.each do |key|
      provider_class = "Provider::#{key.to_s.camelize}".constantize

      assert provider_class < Provider::ExchangeRateConcept, "#{provider_class} does not include Provider::ExchangeRateConcept"
      assert provider_class.ancestors.index(Provider::ExchangeRateConcept::RateValidation) < provider_class.ancestors.index(provider_class),
        "#{provider_class} bypasses Provider::ExchangeRateConcept::RateValidation"
    end
  end
end
