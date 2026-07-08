require "test_helper"

class Provider::FrankfurterTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Frankfurter.new
    @provider.stubs(:throttle_request)
  end

  # ================================
  #        Same-currency shortcut
  # ================================

  test "fetch_exchange_rate returns 1.0 for the same currency without calling the API" do
    @provider.expects(:get_json).never

    response = @provider.fetch_exchange_rate(from: "USD", to: "USD", date: Date.current)

    assert response.success?
    assert_equal 1.0, response.data.rate
    assert_equal "USD", response.data.from
    assert_equal "USD", response.data.to
  end

  test "fetch_exchange_rates returns 1.0 rates for every date in range for the same currency" do
    @provider.expects(:get_json).never
    start_date = Date.current - 3
    end_date = Date.current

    response = @provider.fetch_exchange_rates(from: "EUR", to: "EUR", start_date: start_date, end_date: end_date)

    assert response.success?
    assert_equal 4, response.data.size
    assert response.data.all? { |r| r.rate == 1.0 }
  end

  test "fetch_exchange_rate treats mixed-case same currency as the same-currency shortcut" do
    @provider.expects(:get_json).never

    response = @provider.fetch_exchange_rate(from: "usd", to: "USD", date: Date.current)

    assert response.success?
    assert_equal 1.0, response.data.rate
  end

  test "fetch_exchange_rate matches a lowercase target currency against Frankfurter's uppercase response keys" do
    date = Date.current - 5
    stub_range(from: "USD", to: "INR", body: rates_body(date => { "INR" => 83.1 }))

    response = @provider.fetch_exchange_rate(from: "usd", to: "inr", date: date)

    assert response.success?
    assert_in_delta 83.1, response.data.rate
    assert_equal "USD", response.data.from
    assert_equal "INR", response.data.to
  end

  # ================================
  #        fetch_exchange_rate
  # ================================

  test "fetch_exchange_rate returns the direct cross-rate for a real pair" do
    date = Date.current - 5
    stub_range(from: "INR", to: "CAD", body: rates_body(date => { "CAD" => 0.01484 }))

    response = @provider.fetch_exchange_rate(from: "INR", to: "CAD", date: date)

    assert response.success?
    assert_equal date, response.data.date
    assert_in_delta 0.01484, response.data.rate
    assert_equal "INR", response.data.from
    assert_equal "CAD", response.data.to
  end

  test "fetch_exchange_rate looks back to the prior available date on a weekend/holiday" do
    non_trading_day = Date.current - 5
    prior_trading_day = non_trading_day - 2
    # Frankfurter simply omits weekend/holiday dates rather than returning a row for them.
    stub_range(from: "USD", to: "INR", body: rates_body(prior_trading_day => { "INR" => 83.1 }))

    response = @provider.fetch_exchange_rate(from: "USD", to: "INR", date: non_trading_day)

    assert response.success?
    assert_equal prior_trading_day, response.data.date
    assert_in_delta 83.1, response.data.rate
  end

  test "fetch_exchange_rate fails when Frankfurter has no data in the lookback window" do
    date = Date.current - 5
    stub_range(from: "USD", to: "INR", body: rates_body)

    response = @provider.fetch_exchange_rate(from: "USD", to: "INR", date: date)

    assert_not response.success?
    assert_instance_of Provider::Frankfurter::Error, response.error
  end

  # ================================
  #        fetch_exchange_rates
  # ================================

  test "fetch_exchange_rates returns a sorted range of rates" do
    start_date = Date.current - 5
    end_date = Date.current - 1
    body = rates_body(
      (start_date)     => { "CAD" => 0.0148 },
      (start_date + 1) => { "CAD" => 0.0149 },
      (end_date)       => { "CAD" => 0.0150 }
    )
    stub_range(from: "INR", to: "CAD", body: body)

    response = @provider.fetch_exchange_rates(from: "INR", to: "CAD", start_date: start_date, end_date: end_date)

    assert response.success?
    assert_equal 3, response.data.size
    assert_equal response.data.map(&:date), response.data.map(&:date).sort
    assert_equal start_date, response.data.first.date
    assert_equal end_date, response.data.last.date
  end

  test "fetch_exchange_rates skips dates missing the requested currency" do
    start_date = Date.current - 3
    end_date = Date.current - 1
    body = rates_body(
      start_date => { "CAD" => 0.0148 },
      end_date   => {} # e.g. a currency dropped/renamed mid-range
    )
    stub_range(from: "INR", to: "CAD", body: body)

    response = @provider.fetch_exchange_rates(from: "INR", to: "CAD", start_date: start_date, end_date: end_date)

    assert response.success?
    assert_equal [ start_date ], response.data.map(&:date)
  end

  test "fetch_exchange_rates returns an empty (successful) result for a range with no trading days" do
    start_date = Date.current - 2
    end_date = Date.current - 1
    stub_range(from: "INR", to: "CAD", body: rates_body)

    response = @provider.fetch_exchange_rates(from: "INR", to: "CAD", start_date: start_date, end_date: end_date)

    assert response.success?
    assert_empty response.data
  end

  # ================================
  #        Error handling
  # ================================

  test "fetch_exchange_rates fails without raising when the response is missing the rates key entirely" do
    @provider.stubs(:get_json).returns({ "amount" => 1.0, "base" => "INR" })

    response = @provider.fetch_exchange_rates(
      from: "INR", to: "CAD", start_date: Date.current - 5, end_date: Date.current - 1
    )

    assert_not response.success?
    assert_instance_of Provider::Frankfurter::Error, response.error
  end

  test "fetch_exchange_rates fails without raising on a network error" do
    @provider.stubs(:get_json).raises(Faraday::ConnectionFailed.new("connection refused"))

    response = @provider.fetch_exchange_rates(
      from: "INR", to: "CAD", start_date: Date.current - 5, end_date: Date.current - 1
    )

    assert_not response.success?
    assert_instance_of Provider::Frankfurter::Error, response.error
  end

  test "fetch_exchange_rate fails without raising when the API call errors" do
    @provider.stubs(:get_json).raises(StandardError.new("boom"))

    response = @provider.fetch_exchange_rate(from: "USD", to: "INR", date: Date.current)

    assert_not response.success?
    assert_instance_of Provider::Frankfurter::Error, response.error
  end

  # ================================
  #        healthy? / usage / max_history_days
  # ================================

  test "healthy? returns true when the currencies endpoint responds" do
    @provider.stubs(:get_json).with("/v1/currencies").returns({ "USD" => "United States Dollar" })

    response = @provider.healthy?

    assert response.success?
    assert response.data
  end

  test "healthy? fails when the currencies endpoint returns nothing" do
    @provider.stubs(:get_json).with("/v1/currencies").returns({})

    response = @provider.healthy?

    assert_not response.success?
  end

  test "usage reports a free, keyless plan" do
    response = @provider.usage

    assert response.success?
    assert_equal "Free (no key required)", response.data.plan
    assert_nil response.data.limit
  end

  test "max_history_days is nil (unbounded - ECB data back to 1999)" do
    assert_nil @provider.max_history_days
  end

  private

    def rates_body(dates_to_currencies = {})
      rates = dates_to_currencies.each_with_object({}) do |(date, currencies), hash|
        hash[date.to_s] = currencies
      end
      { "amount" => 1.0, "base" => "INR", "start_date" => "2024-01-01", "end_date" => "2024-01-02", "rates" => rates }
    end

    def stub_range(from:, to:, body:)
      @provider.stubs(:get_json)
        .with(regexp_matches(%r{^/v1/\d{4}-\d{2}-\d{2}\.\.\d{4}-\d{2}-\d{2}$}), has_entries("from" => from, "to" => to))
        .returns(body)
    end
end
