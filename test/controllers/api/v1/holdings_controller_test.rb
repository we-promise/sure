# frozen_string_literal: true

require "test_helper"

class Api::V1::HoldingsControllerTest < ActionDispatch::IntegrationTest
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

    @account = create_investment_account(status: "active", name: "Holding Investment")
    @holding = create_holding(@account, ticker: "HLD#{SecureRandom.hex(4).upcase}")

    other_family = families(:empty)
    other_account = other_family.accounts.create!(
      name: "Other Holding Investment",
      accountable: Investment.new,
      balance: 0,
      currency: "USD"
    )
    @other_holding = create_holding(other_account, ticker: "OHD#{SecureRandom.hex(4).upcase}")
  end

  test "lists holdings scoped to accessible historical accounts" do
    @account.disable!
    active_account = create_investment_account(status: "active", name: "Active Holding")
    active_holding = create_holding(active_account, ticker: "AH#{SecureRandom.hex(4).upcase}")
    pending_deletion_account = create_investment_account(status: "pending_deletion", name: "Pending Delete Holding")
    pending_deletion_holding = create_holding(pending_deletion_account, ticker: "PDH#{SecureRandom.hex(4).upcase}")

    get api_v1_holdings_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    holding_ids = response_data["holdings"].map { |holding| holding["id"] }
    assert_includes holding_ids, @holding.id
    assert_includes holding_ids, active_holding.id
    assert_not_includes holding_ids, pending_deletion_holding.id
    assert_not_includes holding_ids, @other_holding.id
  end

  test "shows a disabled account holding" do
    @account.disable!

    get api_v1_holding_url(@holding), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal @holding.id, response_data["id"]
    assert_equal @account.id, response_data.dig("account", "id")
  end

  test "does not show a pending deletion account holding" do
    pending_deletion_account = create_investment_account(status: "pending_deletion", name: "Pending Delete Show Holding")
    pending_deletion_holding = create_holding(pending_deletion_account, ticker: "PHS#{SecureRandom.hex(4).upcase}")

    get api_v1_holding_url(pending_deletion_holding), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "not_found", response_data["error"]
  end

  test "returns not found for malformed holding id" do
    get api_v1_holding_url("not-a-uuid"), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "not_found", response_data["error"]
  end

  test "requires authentication for index" do
    get api_v1_holdings_url

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "unauthorized", response_data["error"]
  end

  test "requires authentication for show" do
    get api_v1_holding_url(@holding)

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "unauthorized", response_data["error"]
  end

  test "requires read scope for index" do
    get api_v1_holdings_url, headers: api_headers(no_scope_api_key)

    assert_response :forbidden
    response_data = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_data["error"]
  end

  test "requires read scope for show" do
    get api_v1_holding_url(@holding), headers: api_headers(no_scope_api_key)

    assert_response :forbidden
    response_data = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_data["error"]
  end

  test "returns project-standard internal index errors" do
    Api::V1::HoldingsController.any_instance.stubs(:holding_history_scope).raises(StandardError, "boom")

    get api_v1_holdings_url, headers: api_headers(@api_key)

    assert_response :internal_server_error
    response_data = JSON.parse(response.body)
    assert_equal "internal_server_error", response_data["error"]
    assert_equal "An unexpected error occurred", response_data["message"]
  end

  test "rejects malformed account_id filter" do
    get api_v1_holdings_url, params: { account_id: "not-a-uuid" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_match "account_id must be a valid UUID", response_data["message"]
  end

  private

    def create_investment_account(status:, name:)
      @family.accounts.create!(
        name: "#{name} #{SecureRandom.hex(4)}",
        accountable: Investment.new,
        balance: 0,
        currency: "USD",
        status: status
      )
    end

    def create_holding(account, ticker:)
      security = Security.create!(
        ticker: ticker,
        name: "#{ticker} Security",
        country_code: "US",
        exchange_operating_mic: "XNAS"
      )

      account.holdings.create!(
        security: security,
        date: Date.parse("2024-01-15"),
        qty: 1,
        price: 100,
        amount: 100,
        currency: account.currency
      )
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end

    def no_scope_api_key
      @api_key.update_column(:scopes, [])
      @api_key
    end
end
