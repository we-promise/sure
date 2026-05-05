# frozen_string_literal: true

require "test_helper"

class Api::V1::SecuritiesControllerTest < ActionDispatch::IntegrationTest
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
    @holding_security = securities(:aapl)
    @holding_ticker = @holding_security.ticker
    @trade_ticker = "AAPL#{SecureRandom.hex(4).upcase}"

    @trade_security = Security.create!(
      ticker: @trade_ticker,
      name: "Apple Inc.",
      country_code: "US",
      exchange_operating_mic: "XNAS"
    )
    @account.entries.create!(
      name: "Buy AAPL",
      date: Date.parse("2024-01-16"),
      amount: 1800,
      currency: "USD",
      entryable: Trade.new(
        security: @trade_security,
        qty: 10,
        price: 180,
        currency: "USD"
      )
    )

    @unreferenced_security = Security.create!(ticker: "MSFT#{SecureRandom.hex(4).upcase}", name: "Microsoft Corp.", country_code: "US")

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
  end

  test "lists securities referenced by accessible family investment data" do
    get api_v1_securities_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    security_ids = response_data["securities"].map { |security| security["id"] }

    assert_includes security_ids, @holding_security.id
    assert_includes security_ids, @trade_security.id
    assert_not_includes security_ids, @unreferenced_security.id
    assert_not_includes security_ids, @other_security.id
    assert response_data.key?("pagination")
  end

  test "shows a scoped security" do
    get api_v1_security_url(@holding_security), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal @holding_security.id, response_data["id"]
    assert_equal @holding_ticker, response_data["ticker"]
    assert_equal @holding_security.exchange_operating_mic, response_data["exchange_operating_mic"]
    assert_equal "standard", response_data["kind"]
    assert_not response_data.key?("price_provider")
  end

  test "returns not found for another family's security" do
    get api_v1_security_url(@other_security), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "returns not found for malformed security id" do
    get api_v1_security_url("not-a-uuid"), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "filters securities by ticker" do
    get api_v1_securities_url, params: { ticker: @trade_ticker.downcase }, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal [ @trade_security.id ], response_data["securities"].map { |security| security["id"] }
  end

  test "filters securities by exchange operating mic" do
    get api_v1_securities_url, params: { exchange_operating_mic: " xnas " }, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal [ @holding_security.id, @trade_security.id ], response_data["securities"].map { |security| security["id"] }
  end

  test "caps per_page at documented maximum" do
    get api_v1_securities_url, params: { per_page: 250 }, headers: api_headers(@api_key)

    assert_response :success
    assert_equal 100, JSON.parse(response.body).dig("pagination", "per_page")
  end

  test "rejects invalid kind filter" do
    get api_v1_securities_url, params: { kind: "unsupported" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "rejects malformed offline filter" do
    get api_v1_securities_url, params: { offline: "maybe" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_includes response_data["errors"], "offline must be true or false"
  end

  test "rejects blank offline filter" do
    get api_v1_securities_url, params: { offline: "" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_includes response_data["errors"], "offline must be true or false"
  end

  test "requires authentication" do
    get api_v1_securities_url

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

    get api_v1_securities_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
