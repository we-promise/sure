require "test_helper"

class ExchangeRatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "returns rate for different currencies" do
    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: Date.current,
      rate: 1.2
    )

    get exchange_rate_url, params: {
      from: "EUR",
      to: "USD",
      date: Date.current
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 1.2, json_response["rate"]
  end

  test "returns same_currency flag for matching currencies" do
    get exchange_rate_url, params: {
      from: "USD",
      to: "USD"
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert json_response["same_currency"]
    assert_equal 1.0, json_response["rate"]
  end

  test "uses provided date for rate lookup" do
    custom_date = 3.days.ago.to_date
    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: custom_date,
      rate: 1.25
    )

    get exchange_rate_url, params: {
      from: "EUR",
      to: "USD",
      date: custom_date
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 1.25, json_response["rate"]
  end

  test "defaults to current date when not provided" do
    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: Date.current,
      rate: 1.2
    )

    get exchange_rate_url, params: {
      from: "EUR",
      to: "USD"
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 1.2, json_response["rate"]
  end

  test "returns 400 when from currency is missing" do
    get exchange_rate_url, params: {
      to: "USD"
    }

    assert_response :bad_request
    json_response = JSON.parse(response.body)
    assert_equal "from and to currencies are required", json_response["error"]
  end

  test "returns 400 when to currency is missing" do
    get exchange_rate_url, params: {
      from: "EUR"
    }

    assert_response :bad_request
    json_response = JSON.parse(response.body)
    assert_equal "from and to currencies are required", json_response["error"]
  end

  test "returns 400 on invalid date format" do
    get exchange_rate_url, params: {
      from: "EUR",
      to: "USD",
      date: "not-a-date"
    }

    assert_response :bad_request
    json_response = JSON.parse(response.body)
    assert_equal "Invalid date format", json_response["error"]
  end

  test "returns 404 when rate not found" do
    get exchange_rate_url, params: {
      from: "EUR",
      to: "USD",
      date: Date.current
    }

    assert_response :not_found
    json_response = JSON.parse(response.body)
    assert_equal "Exchange rate not found", json_response["error"]
  end

  test "handles uppercase and lowercase currency codes" do
    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: Date.current,
      rate: 1.2
    )

    get exchange_rate_url, params: {
      from: "eur",
      to: "usd"
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 1.2, json_response["rate"]
  end

  test "returns numeric rate even when object has rate method" do
    # Create mock object that returns a rate
    rate_obj = OpenStruct.new(rate: 1.2)

    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "EUR", to: "USD", date: Date.current)
                .returns(rate_obj)

    get exchange_rate_url, params: {
      from: "EUR",
      to: "USD"
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 1.2, json_response["rate"]
    assert_instance_of Float, json_response["rate"]
  end

  test "returns error when find_or_fetch_rate raises exception" do
    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "EUR", to: "USD", date: Date.current)
                .raises(StandardError, "Rate fetch failed")

    get exchange_rate_url, params: {
      from: "EUR",
      to: "USD"
    }

    assert_response :bad_request
    json_response = JSON.parse(response.body)
    assert_equal "Failed to fetch exchange rate", json_response["error"]
  end
end
