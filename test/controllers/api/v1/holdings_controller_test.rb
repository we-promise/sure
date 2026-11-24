# frozen_string_literal: true

require "test_helper"

class Api::V1::HoldingsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

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
    @holding = holdings(:one)

    # An account owned by another family member, never shared with @user.
    @other_member = users(:family_member)
    @private_account = @family.accounts.create!(
      name: "Member Brokerage",
      accountable: Investment.new,
      balance: 5000,
      currency: "USD",
      owner: @other_member
    )
    @private_holding = @private_account.holdings.create!(
      security: securities(:msft),
      date: Date.current,
      qty: 5,
      price: 100,
      amount: 500,
      currency: "USD"
    )
  end

  test "lists holdings scoped to accessible accounts" do
    get api_v1_holdings_url, headers: api_headers(@api_key)

    assert_response :success
    holding_ids = JSON.parse(response.body)["holdings"].map { |holding| holding["id"] }
    assert_includes holding_ids, @holding.id
    assert_not_includes holding_ids, @private_holding.id
  end

  test "account_ids filter cannot reach inaccessible accounts" do
    get api_v1_holdings_url,
        params: { account_ids: [ @private_account.id ] },
        headers: api_headers(@api_key)

    assert_response :success
    holding_ids = JSON.parse(response.body)["holdings"].map { |holding| holding["id"] }
    assert_not_includes holding_ids, @private_holding.id
  end

  test "account_id filter cannot reach inaccessible accounts" do
    get api_v1_holdings_url,
        params: { account_id: @private_account.id },
        headers: api_headers(@api_key)

    assert_response :success
    holding_ids = JSON.parse(response.body)["holdings"].map { |holding| holding["id"] }
    assert_not_includes holding_ids, @private_holding.id
  end

  test "shows an accessible holding" do
    get api_v1_holding_url(@holding), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal @holding.id, response_data["id"]
  end

  test "returns not found for an inaccessible holding" do
    get api_v1_holding_url(@private_holding), headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "requires authentication" do
    get api_v1_holdings_url

    assert_response :unauthorized
  end

  test "a position's current row lists its open lots, oldest first" do
    current, first_buy, second_buy = lot_position
    HoldingLot.find_by!(source_entry: second_buy).set_manual_total_cost!(600)
    materialize(current.security)

    get api_v1_holding_url(current), headers: api_headers(@api_key)

    assert_response :success
    lots = JSON.parse(response.body)["lots"]
    assert_equal [ first_buy.date.iso8601, second_buy.date.iso8601 ], lots.map { |lot| lot["acquired_on"] }
    assert_equal [ "60.0", "40.0" ], lots.map { |lot| lot["qty"] }
    assert_equal [ "$12.00", "$15.00" ], lots.map { |lot| lot["unit_cost"] }, "the second lot's cost is the user's $600 over 40"
    assert_equal [ false, true ], lots.map { |lot| lot["manual_cost"] }
    assert_equal [ false, false ], lots.map { |lot| lot["opening"] }
    assert_equal [ first_buy.entryable_id, second_buy.entryable_id ], lots.map { |lot| lot["trade_id"] }
  end

  test "units held before the first trade are listed as the opening lot, first" do
    current, = lot_position
    HoldingLot.create!(account: @account, security: current.security, origin_security: current.security, qty: 5, currency: "USD")
    current.update_columns(qty: current.qty + 5)

    get api_v1_holding_url(current), headers: api_headers(@api_key)

    first = JSON.parse(response.body)["lots"].first
    assert_equal [ true, nil, "5.0", nil, nil ], first.values_at("opening", "acquired_on", "qty", "unit_cost", "trade_id")
  end

  # The stored lots are the position as it stands, so an earlier row, or a
  # position whose lots do not add up to it, has none to show.
  test "an earlier row, or a position its lots do not add up to, has null lots" do
    current, first_buy = lot_position
    earlier = @account.holdings.find_by!(security: current.security, date: first_buy.date)

    get api_v1_holding_url(earlier), headers: api_headers(@api_key)
    response_data = JSON.parse(response.body)
    assert response_data.key?("lots")
    assert_nil response_data["lots"]

    current.update_columns(qty: current.qty + 1)
    get api_v1_holding_url(current), headers: api_headers(@api_key)
    assert_nil JSON.parse(response.body)["lots"]
  end

  test "listing holdings reads lots in the same number of queries however many positions" do
    lot_position(ticker: "LOTA")
    one = holding_lot_queries { get api_v1_holdings_url, headers: api_headers(@api_key) }
    lot_position(ticker: "LOTB")
    lot_position(ticker: "LOTC")
    three = holding_lot_queries { get api_v1_holdings_url, headers: api_headers(@api_key) }

    assert_response :success
    assert_equal one, three
    assert_equal 3, JSON.parse(response.body)["holdings"].count { |holding| holding["lots"].present? }
  end

  private

    # Two buys of one security, 60 at $12 two days ago and 40 at $20
    # yesterday, materialized as a sync does.
    def lot_position(ticker: "LOTS")
      security = Security.create!(ticker: ticker, name: ticker)
      Security::Price.insert_all((2.days.ago.to_date..Date.current).map { |date| { security_id: security.id, date: date, price: 30, currency: "USD" } })
      first_buy = create_trade(security, account: @account, qty: 60, price: 12, date: 2.days.ago.to_date)
      second_buy = create_trade(security, account: @account, qty: 40, price: 20, date: 1.day.ago.to_date)
      materialize(security)
      [ @account.holdings.find_by!(security: security, date: Date.current), first_buy, second_buy ]
    end

    def materialize(security)
      Holding::Materializer.new(@account.reload, strategy: :forward, security_ids: [ security.id ]).materialize_holdings
    end

    def holding_lot_queries
      count = 0
      counter = ->(*, payload) { count += 1 if payload[:sql].include?("holding_lots") }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
      count
    end


    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
