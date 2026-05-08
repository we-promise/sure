# frozen_string_literal: true

require "test_helper"

class Api::V1::BalancesControllerTest < ActionDispatch::IntegrationTest
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

    @account = @family.accounts.create!(
      name: "Balance Checking",
      accountable: Depository.new,
      balance: 1234.56,
      currency: "USD"
    )
    @balance = @account.balances.create!(
      date: Date.parse("2024-01-15"),
      balance: 1234.56,
      cash_balance: 1234.56,
      start_cash_balance: 1000,
      start_non_cash_balance: 0,
      cash_inflows: 234.56,
      cash_outflows: 0,
      currency: "USD"
    )

    other_family = families(:empty)
    other_account = other_family.accounts.create!(
      name: "Other Balance Checking",
      accountable: Depository.new,
      balance: 500,
      currency: "USD"
    )
    @other_balance = other_account.balances.create!(
      date: Date.parse("2024-01-15"),
      balance: 500,
      cash_balance: 500,
      currency: "USD"
    )
  end

  test "lists balances scoped to accessible family accounts" do
    get api_v1_balances_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data.key?("balances")
    assert response_data.key?("pagination")
    assert_includes response_data["balances"].map { |balance| balance["id"] }, @balance.id
    assert_not_includes response_data["balances"].map { |balance| balance["id"] }, @other_balance.id
  end

  test "shows a balance" do
    get api_v1_balance_url(@balance), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal @balance.id, response_data["id"]
    assert_equal "2024-01-15", response_data["date"]
    assert_equal @account.id, response_data.dig("account", "id")
    assert_kind_of Integer, response_data["balance_cents"]
    assert_kind_of Integer, response_data["end_balance_cents"]
  end

  test "renders nullable cash balance fields" do
    balance_without_cash = @account.balances.create!(
      date: Date.parse("2024-01-16"),
      balance: 1234.56,
      currency: "USD"
    )
    balance_without_cash.update_column(:cash_balance, nil)

    get api_v1_balance_url(balance_without_cash), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_nil response_data["cash_balance"]
    assert_nil response_data["cash_balance_cents"]
  end

  test "renders nullable account type" do
    @account.update_columns(accountable_type: nil, accountable_id: nil)

    get api_v1_balance_url(@balance), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_nil response_data.dig("account", "account_type")
  end

  test "returns not found for another family's balance" do
    get api_v1_balance_url(@other_balance), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "returns not found for malformed balance id" do
    get api_v1_balance_url("not-a-uuid"), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "filters balances by account_id" do
    get api_v1_balances_url,
        params: { account_id: @account.id },
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["balances"].map { |balance| balance["id"] }, @balance.id
  end

  test "filters balances by currency" do
    eur_balance = @account.balances.create!(
      date: Date.parse("2024-01-16"),
      balance: 100,
      currency: "EUR"
    )

    get api_v1_balances_url,
        params: { currency: "usd" },
        headers: api_headers(@api_key)

    assert_response :success
    balance_ids = JSON.parse(response.body)["balances"].map { |balance| balance["id"] }
    assert_includes balance_ids, @balance.id
    assert_not_includes balance_ids, eur_balance.id
  end

  test "filters balances by date range" do
    get api_v1_balances_url,
        params: { start_date: "2024-01-15", end_date: "2024-01-15" },
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["balances"].map { |balance| balance["id"] }, @balance.id
  end

  test "rejects malformed account_id filter" do
    get api_v1_balances_url, params: { account_id: "not-a-uuid" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "rejects invalid date filters" do
    get api_v1_balances_url, params: { start_date: "01/15/2024" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "requires authentication" do
    get api_v1_balances_url

    assert_response :unauthorized
  end

  test "requires read scope" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "mobile",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get api_v1_balances_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
