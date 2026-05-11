# frozen_string_literal: true

require "test_helper"

class Api::V1::TradesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @investment_account = accounts(:investment)
  end

  test "create dividend with security returns 201" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "dividend",
        date: Date.current,
        amount: 25.50,
        currency: "USD",
        ticker: "AAPL|XNAS"
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert_equal "Dividend: AAPL", body["name"]
    assert_equal "Dividend", body["investment_activity_label"]
    assert_equal 0, body["qty"].to_i
  end

  test "create dividend without security returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "dividend",
        date: Date.current,
        amount: 25.50
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
  end

  test "create dividend without amount returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "dividend",
        date: Date.current,
        ticker: "AAPL|XNAS"
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
  end

  test "create buy trade returns 201" do
    security = Security.create!(ticker: "TEST", name: "Test Security", country_code: "US")

    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 10,
        price: 100.00,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert_equal "Buy", body["investment_activity_label"]
  end

  test "create sell trade returns 201" do
    security = Security.create!(ticker: "TEST", name: "Test Security", country_code: "US")

    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "sell",
        date: Date.current,
        qty: 10,
        price: 100.00,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert_equal "Sell", body["investment_activity_label"]
  end

  test "invalid type returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "invalid",
        date: Date.current
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
  end

  test "create deposit returns 201" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "deposit",
        date: Date.current,
        amount: 175.25,
        currency: "USD"
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert_match(/Deposit to/, body["name"])
    assert_equal "Transaction", body["entryable_type"]
  end

  test "create withdrawal returns 201" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "withdrawal",
        date: Date.current,
        amount: 100.00,
        currency: "USD"
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert_match(/Withdrawal/, body["name"])
    assert_equal "Transaction", body["entryable_type"]
  end

  test "create deposit without amount returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "deposit",
        date: Date.current
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
  end

  test "create deposit with transfer_account_id creates linked transfer" do
    depository = accounts(:depository)

    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "deposit",
        date: Date.current,
        amount: 500.00,
        currency: "USD",
        transfer_account_id: depository.id
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert_equal "Transaction", body["entryable_type"]
    assert body["account"]["id"].present?
    assert body["account"]["account_type"].present?
  end

  test "create interest returns 201" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "interest",
        date: Date.current,
        amount: 25.00,
        currency: "USD"
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert_equal "Interest", body["investment_activity_label"]
  end

  test "create interest without amount returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "interest",
        date: Date.current
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
  end

  test "create requires read_write scope" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 10,
        price: 100
      } },
      headers: api_headers(read_only_api_key)

    assert_response :forbidden
  end

  private

    def read_write_api_key
      @read_write_api_key ||= ApiKey.create!(
        user: @user,
        name: "Test RW Key",
        key: ApiKey.generate_secure_key,
        scopes: %w[read_write],
        source: "web"
      )
    end

    def read_only_api_key
      @read_only_api_key ||= ApiKey.create!(
        user: @user,
        name: "Test RO Key",
        key: ApiKey.generate_secure_key,
        scopes: %w[read],
        source: "mobile"
      )
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
