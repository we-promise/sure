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
end
