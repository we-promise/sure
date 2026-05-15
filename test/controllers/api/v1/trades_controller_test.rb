# frozen_string_literal: true

require "test_helper"

class Api::V1::TradesControllerTest < ActionDispatch::IntegrationTest
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

    @account = create_investment_account(status: "active", name: "Trade Investment")
    @trade = create_trade(@account, ticker: "TRD#{SecureRandom.hex(4).upcase}")

    other_family = families(:empty)
    other_account = other_family.accounts.create!(
      name: "Other Trade Investment",
      accountable: Investment.new,
      balance: 0,
      currency: "USD"
    )
    @other_trade = create_trade(other_account, ticker: "OTH#{SecureRandom.hex(4).upcase}")
  end

  test "lists trades scoped to accessible historical accounts" do
    @account.disable!
    pending_deletion_account = create_investment_account(status: "pending_deletion", name: "Pending Delete Trade")
    pending_deletion_trade = create_trade(pending_deletion_account, ticker: "PDT#{SecureRandom.hex(4).upcase}")

    get api_v1_trades_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    trade_ids = response_data["trades"].map { |trade| trade["id"] }
    assert_includes trade_ids, @trade.id
    assert_not_includes trade_ids, pending_deletion_trade.id
    assert_not_includes trade_ids, @other_trade.id
  end

  test "shows a disabled account trade" do
    @account.disable!

    get api_v1_trade_url(@trade), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal @trade.id, response_data["id"]
    assert_equal @account.id, response_data.dig("account", "id")
  end

  test "does not show a pending deletion account trade" do
    pending_deletion_account = create_investment_account(status: "pending_deletion", name: "Pending Delete Show Trade")
    pending_deletion_trade = create_trade(pending_deletion_account, ticker: "PDS#{SecureRandom.hex(4).upcase}")

    get api_v1_trade_url(pending_deletion_trade), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "not_found", response_data["error"]
  end

  test "returns not found for malformed trade id" do
    get api_v1_trade_url("not-a-uuid"), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "not_found", response_data["error"]
  end

  test "requires authentication for index" do
    get api_v1_trades_url

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "unauthorized", response_data["error"]
  end

  test "requires authentication for show" do
    get api_v1_trade_url(@trade)

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "unauthorized", response_data["error"]
  end

  test "creates trade with write scope" do
    assert_difference("Trade.count", 1) do
      post api_v1_trades_url,
        params: { trade: valid_trade_create_params },
        headers: api_headers(read_write_api_key),
        as: :json
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal @account.id, response_data.dig("account", "id")
  end

  test "does not create trade for read-only shared account" do
    member_key = read_write_api_key_for(users(:family_member), source: "web")
    share_account_with_member(permission: "read_only")

    assert_no_difference("Trade.count") do
      post api_v1_trades_url,
        params: { trade: valid_trade_create_params },
        headers: api_headers(member_key),
        as: :json
    end

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "not_found", response_data["error"]
    assert_equal "Account not found", response_data["message"]
  end

  test "rejects invalid trade create params" do
    assert_no_difference("Trade.count") do
      post api_v1_trades_url,
        params: { trade: valid_trade_create_params.except(:type) },
        headers: api_headers(read_write_api_key),
        as: :json
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "rejects invalid date on create" do
    assert_no_difference("Trade.count") do
      post api_v1_trades_url,
        params: { trade: valid_trade_create_params(date: "not-a-date") },
        headers: api_headers(read_write_api_key),
        as: :json
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_match "Invalid date format", response_data["message"]
  end

  test "updates trade with patch and write scope" do
    patch api_v1_trade_url(@trade),
      params: { trade: { date: "2024-02-01", qty: 2, price: 125, type: "sell" } },
      headers: api_headers(read_write_api_key),
      as: :json

    assert_response :success
    @trade.reload
    assert_equal Date.parse("2024-02-01"), @trade.entry.date
    assert_equal BigDecimal("-2"), @trade.qty
    assert_equal BigDecimal("125"), @trade.price
  end

  test "updates trade with put and write scope" do
    put api_v1_trade_url(@trade),
      params: { trade: { qty: 3, price: 75, type: "buy" } },
      headers: api_headers(read_write_api_key),
      as: :json

    assert_response :success
    @trade.reload
    assert_equal BigDecimal("3"), @trade.qty
    assert_equal BigDecimal("75"), @trade.price
  end

  test "does not update trade for read-only shared account" do
    member_key = read_write_api_key_for(users(:family_member), source: "web")
    share_account_with_member(permission: "read_only")

    patch api_v1_trade_url(@trade),
      params: { trade: { qty: 2, price: 100, type: "buy" } },
      headers: api_headers(member_key),
      as: :json

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "not_found", response_data["error"]
    assert_equal "Trade not found", response_data["message"]
    assert_equal BigDecimal("1"), @trade.reload.qty
  end

  test "rejects invalid date on update" do
    patch api_v1_trade_url(@trade),
      params: { trade: { date: "not-a-date" } },
      headers: api_headers(read_write_api_key),
      as: :json

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_match "Invalid date format", response_data["message"]
  end

  test "returns not found for malformed trade id on write" do
    patch api_v1_trade_url("not-a-uuid"),
      params: { trade: { qty: 2, price: 100, type: "buy" } },
      headers: api_headers(read_write_api_key),
      as: :json

    assert_response :not_found
    assert_equal "not_found", JSON.parse(response.body)["error"]
  end

  test "destroys trade with write scope" do
    trade = create_trade(@account, ticker: "DEL#{SecureRandom.hex(4).upcase}")

    assert_difference("Trade.count", -1) do
      delete api_v1_trade_url(trade), headers: api_headers(read_write_api_key)
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "Trade deleted successfully", response_data["message"]
  end

  test "does not destroy trade for read-only shared account" do
    member_key = read_write_api_key_for(users(:family_member), source: "web")
    share_account_with_member(permission: "read_only")

    assert_no_difference("Trade.count") do
      delete api_v1_trade_url(@trade), headers: api_headers(member_key)
    end

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "not_found", response_data["error"]
    assert_equal "Trade not found", response_data["message"]
  end

  test "requires authentication for create" do
    assert_no_difference("Trade.count") do
      post api_v1_trades_url, params: { trade: valid_trade_create_params }, as: :json
    end

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "unauthorized", response_data["error"]
  end

  test "blocks read-only key from write actions" do
    assert_no_difference("Trade.count") do
      post api_v1_trades_url,
        params: { trade: valid_trade_create_params },
        headers: api_headers(@api_key),
        as: :json
    end
    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]

    patch api_v1_trade_url(@trade),
      params: { trade: { qty: 2, price: 100, type: "buy" } },
      headers: api_headers(@api_key),
      as: :json
    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]

    delete api_v1_trade_url(@trade), headers: api_headers(@api_key)
    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "returns project-standard internal index errors" do
    Api::V1::TradesController.any_instance.stubs(:trade_history_scope).raises(StandardError, "boom")

    get api_v1_trades_url, headers: api_headers(@api_key)

    assert_response :internal_server_error
    response_data = JSON.parse(response.body)
    assert_equal "internal_server_error", response_data["error"]
    assert_equal "An unexpected error occurred", response_data["message"]
  end

  test "rejects malformed account_id filter" do
    get api_v1_trades_url, params: { account_id: "not-a-uuid" }, headers: api_headers(@api_key)

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

    def create_trade(account, ticker:)
      security = Security.create!(
        ticker: ticker,
        name: "#{ticker} Security",
        country_code: "US",
        exchange_operating_mic: "XNAS"
      )

      account.entries.create!(
        name: "Buy #{ticker}",
        date: Date.parse("2024-01-15"),
        amount: 100,
        currency: account.currency,
        entryable: Trade.new(
          security: security,
          qty: 1,
          price: 100,
          currency: account.currency
        )
      ).entryable
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end

    def read_write_api_key
      @read_write_api_key ||= ApiKey.create!(
        user: @user,
        name: "Test Write Key",
        scopes: [ "read_write" ],
        source: "mobile",
        display_key: "test_write_#{SecureRandom.hex(8)}"
      )
    end

    def read_write_api_key_for(user, source:)
      user.api_keys.active.where(source: source).destroy_all
      ApiKey.create!(
        user: user,
        name: "Shared Account Write Key",
        scopes: [ "read_write" ],
        source: source,
        display_key: "test_shared_write_#{SecureRandom.hex(8)}"
      )
    end

    def share_account_with_member(permission:)
      @account.account_shares.where(user: users(:family_member)).destroy_all
      @account.account_shares.create!(
        user: users(:family_member),
        permission: permission,
        include_in_finances: true
      )
    end

    def valid_trade_create_params(overrides = {})
      security = Security.create!(
        ticker: "NEW#{SecureRandom.hex(4).upcase}",
        name: "New Trade Security",
        country_code: "US",
        exchange_operating_mic: "XNAS"
      )

      {
        account_id: @account.id,
        date: "2024-02-01",
        qty: 2,
        price: 50,
        type: "buy",
        security_id: security.id,
        currency: @account.currency
      }.merge(overrides)
    end
end
