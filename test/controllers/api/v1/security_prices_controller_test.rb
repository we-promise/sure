# frozen_string_literal: true

require "test_helper"

class Api::V1::SecurityPricesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    @account = accounts(:investment)
    @security = securities(:aapl)
    @ticker = @security.ticker
    @security_price = security_prices(:one)
    @eur_price = Security::Price.create!(
      security: @security,
      date: @security_price.date,
      price: BigDecimal("250.5000"),
      currency: "EUR"
    )

    other_account = families(:empty).accounts.create!(
      name: "Other Investment Account",
      accountable: Investment.new,
      balance: 1000,
      currency: "USD"
    )
    @other_security = Security.create!(ticker: "GOOG#{SecureRandom.hex(4).upcase}", name: "Alphabet Inc.", country_code: "US")
    other_account.holdings.create!(
      security: @other_security,
      date: Date.parse("2024-01-15"),
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD"
    )
    @other_price = Security::Price.create!(
      security: @other_security,
      date: Date.parse("2024-01-15"),
      price: 100,
      currency: "USD"
    )
  end

  test "lists prices for securities referenced by accessible family investment data" do
    get api_v1_security_prices_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    price_ids = response_data["security_prices"].map { |price| price["id"] }

    assert_includes price_ids, @security_price.id
    assert_not_includes price_ids, @other_price.id
    assert response_data.key?("pagination")
  end

  test "shows a scoped security price" do
    get api_v1_security_price_url(@security_price), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal @security_price.id, response_data["id"]
    assert_equal @security_price.date.iso8601, response_data["date"]
    assert_equal "215.0000", response_data["price_amount"]
    assert_equal @security.id, response_data.dig("security", "id")
  end

  test "returns not found for another family's security price" do
    get api_v1_security_price_url(@other_price), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "returns not found for malformed security price id" do
    get api_v1_security_price_url("not-a-uuid"), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "filters security prices by security_id" do
    get api_v1_security_prices_url, params: { security_id: @security.id }, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["security_prices"].map { |price| price["id"] }, @security_price.id
    assert response_data["security_prices"].all? { |price| price.dig("security", "id") == @security.id }
  end

  test "filters security prices by date range and provisional status" do
    get api_v1_security_prices_url,
        params: { start_date: @security_price.date.iso8601, end_date: @security_price.date.iso8601, currency: "USD", provisional: false },
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal [ @security_price.id ], response_data["security_prices"].map { |price| price["id"] }
  end

  test "rejects blank provisional filter" do
    get api_v1_security_prices_url,
        params: { provisional: "" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_includes response_data["errors"], "provisional must be true or false"
  end

  test "filters security prices by currency" do
    get api_v1_security_prices_url,
        params: { currency: " usd " },
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["security_prices"].map { |price| price["id"] }, @security_price.id
    assert_not_includes response_data["security_prices"].map { |price| price["id"] }, @eur_price.id
  end

  test "rejects malformed provisional filter" do
    get api_v1_security_prices_url,
        params: { provisional: "maybe" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_includes response_data["errors"], "provisional must be true or false"
  end

  test "caps per_page at documented maximum" do
    get api_v1_security_prices_url, params: { per_page: 250 }, headers: api_headers(@api_key)

    assert_response :success
    assert_equal 100, JSON.parse(response.body).dig("pagination", "per_page")
  end

  test "rejects malformed security_id filter" do
    get api_v1_security_prices_url, params: { security_id: "not-a-uuid" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "rejects invalid date filters" do
    get api_v1_security_prices_url, params: { start_date: "01/15/2024" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "requires authentication" do
    get api_v1_security_prices_url

    assert_response :unauthorized
  end

  test "requires read scope" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "web",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get api_v1_security_prices_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
