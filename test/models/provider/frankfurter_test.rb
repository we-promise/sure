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

  test "fetch_exchange_rate strips non-letter characters from currency codes before building the URL path" do
    date = Date.current - 5
    body = { "date" => date.to_s, "base" => "USD", "quote" => "INR", "rate" => 83.1 }
    @provider.expects(:get_json).with("/rate/USD/INR", has_entries("date" => date.to_s)).returns(body)

    response = @provider.fetch_exchange_rate(from: "US/../D", to: "IN;R", date: date)

    assert response.success?
    assert_equal "USD", response.data.from
    assert_equal "INR", response.data.to
  end

  # ================================
  #        fetch_exchange_rate (GET /rate/{base}/{quote})
  # ================================

  test "fetch_exchange_rate returns the direct cross-rate for a real pair" do
    date = Date.current - 5
    stub_rate(from: "INR", to: "CAD", date: date, body: { "date" => date.to_s, "base" => "INR", "quote" => "CAD", "rate" => 0.01484 })

    response = @provider.fetch_exchange_rate(from: "INR", to: "CAD", date: date)

    assert response.success?
    assert_equal date, response.data.date
    assert_in_delta 0.01484, response.data.rate
    assert_equal "INR", response.data.from
    assert_equal "CAD", response.data.to
  end

  test "fetch_exchange_rate matches a lowercase target currency against Frankfurter's uppercase response" do
    date = Date.current - 5
    stub_rate(from: "USD", to: "INR", date: date, body: { "date" => date.to_s, "base" => "USD", "quote" => "INR", "rate" => 83.1 })

    response = @provider.fetch_exchange_rate(from: "usd", to: "inr", date: date)

    assert response.success?
    assert_in_delta 83.1, response.data.rate
    assert_equal "USD", response.data.from
    assert_equal "INR", response.data.to
  end

  test "fetch_exchange_rate uses whatever date Frankfurter's own carry-forward returns" do
    # v2 carries weekends/holidays forward server-side, so the response date
    # can legitimately differ from the requested one - we trust it as-is.
    requested_date = Date.current - 5
    carried_forward_date = requested_date - 2
    stub_rate(from: "USD", to: "INR", date: requested_date, body: { "date" => carried_forward_date.to_s, "base" => "USD", "quote" => "INR", "rate" => 91.0 })

    response = @provider.fetch_exchange_rate(from: "USD", to: "INR", date: requested_date)

    assert response.success?
    assert_equal carried_forward_date, response.data.date
    assert_in_delta 91.0, response.data.rate
  end

  test "fetch_exchange_rate fails without raising when the API call errors" do
    @provider.stubs(:get_json).raises(StandardError.new("boom"))

    response = @provider.fetch_exchange_rate(from: "USD", to: "INR", date: Date.current)

    assert_not response.success?
    assert_instance_of Provider::Frankfurter::Error, response.error
  end

  test "fetch_exchange_rate fails without raising when the response is missing a rate" do
    date = Date.current - 5
    stub_rate(from: "USD", to: "INR", date: date, body: { "date" => date.to_s, "base" => "USD", "quote" => "INR" })

    response = @provider.fetch_exchange_rate(from: "USD", to: "INR", date: date)

    assert_not response.success?
    assert_instance_of Provider::Frankfurter::Error, response.error
  end

  # ================================
  #        fetch_exchange_rates (GET /rates)
  # ================================

  test "fetch_exchange_rates returns a sorted range of rates" do
    start_date = Date.current - 5
    end_date = Date.current - 1
    body = [
      { "date" => start_date.to_s, "base" => "INR", "quote" => "CAD", "rate" => 0.0148 },
      { "date" => (start_date + 1).to_s, "base" => "INR", "quote" => "CAD", "rate" => 0.0149 },
      { "date" => end_date.to_s, "base" => "INR", "quote" => "CAD", "rate" => 0.0150 }
    ]
    stub_range(from: "INR", to: "CAD", start_date: start_date, end_date: end_date, body: body)

    response = @provider.fetch_exchange_rates(from: "INR", to: "CAD", start_date: start_date, end_date: end_date)

    assert response.success?
    assert_equal 3, response.data.size
    assert_equal response.data.map(&:date), response.data.map(&:date).sort
    assert_equal start_date, response.data.first.date
    assert_equal end_date, response.data.last.date
  end

  test "fetch_exchange_rates includes every calendar day (v2 carries weekends/holidays forward itself)" do
    start_date = Date.new(2024, 3, 16) # Saturday
    end_date = Date.new(2024, 3, 17)   # Sunday
    body = [
      { "date" => "2024-03-16", "base" => "INR", "quote" => "CAD", "rate" => 0.01631 },
      { "date" => "2024-03-17", "base" => "INR", "quote" => "CAD", "rate" => 0.01631 }
    ]
    stub_range(from: "INR", to: "CAD", start_date: start_date, end_date: end_date, body: body)

    response = @provider.fetch_exchange_rates(from: "INR", to: "CAD", start_date: start_date, end_date: end_date)

    assert response.success?
    assert_equal 2, response.data.size
  end

  test "fetch_exchange_rates ignores entries for a different quote currency" do
    start_date = Date.current - 3
    end_date = Date.current - 1
    body = [
      { "date" => start_date.to_s, "base" => "INR", "quote" => "CAD", "rate" => 0.0148 },
      { "date" => start_date.to_s, "base" => "INR", "quote" => "USD", "rate" => 0.012 }
    ]
    stub_range(from: "INR", to: "CAD", start_date: start_date, end_date: end_date, body: body)

    response = @provider.fetch_exchange_rates(from: "INR", to: "CAD", start_date: start_date, end_date: end_date)

    assert response.success?
    assert_equal 1, response.data.size
    assert_equal "CAD", response.data.first.to
  end

  # ================================
  #        Error handling
  # ================================

  test "fetch_exchange_rates fails without raising when the response is not an array" do
    @provider.stubs(:get_json).returns({ "status" => 422, "message" => "invalid currency" })

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

  # ================================
  #        healthy? / usage / max_history_days
  # ================================

  test "healthy? returns true when the currencies endpoint responds" do
    @provider.stubs(:get_json).with("/currencies").returns([ { "iso_code" => "USD", "name" => "United States Dollar" } ])

    response = @provider.healthy?

    assert response.success?
    assert response.data
  end

  test "healthy? fails when the currencies endpoint returns nothing" do
    @provider.stubs(:get_json).with("/currencies").returns([])

    response = @provider.healthy?

    assert_not response.success?
  end

  test "usage reports a free, keyless plan" do
    response = @provider.usage

    assert response.success?
    assert_equal "Free (no key required)", response.data.plan
    assert_nil response.data.limit
  end

  test "max_history_days is nil (unbounded)" do
    assert_nil @provider.max_history_days
  end

  private

    def stub_rate(from:, to:, date:, body:)
      @provider.stubs(:get_json)
        .with("/rate/#{from}/#{to}", has_entries("date" => date.to_s))
        .returns(body)
    end

    def stub_range(from:, to:, start_date:, end_date:, body:)
      @provider.stubs(:get_json)
        .with("/rates", has_entries("base" => from, "quotes" => to, "from" => start_date.to_s, "to" => end_date.to_s))
        .returns(body)
    end
end
