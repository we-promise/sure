require "test_helper"

class SimplefinHoldingsApplyJobTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(family: @family, name: "SF", access_url: "https://example.com/x")

    @account = accounts(:investment)

    # Link SFA to existing investment account via legacy association for simplicity
    @sfa = @item.simplefin_accounts.create!(
      name: "Invest",
      account_id: "sf_invest_1",
      currency: "USD",
      account_type: "investment",
      current_balance: 10_000
    )
    @account.update!(simplefin_account_id: @sfa.id)
  end

  test "materializes holdings from raw_holdings_payload and is idempotent" do
    # Clear existing fixture holdings so we can test clean creation
    @account.holdings.delete_all

    # Two holdings: one AAPL (existing security), one NEWCO (should be created)
    @sfa.update!(
      raw_holdings_payload: [
        {
          "id" => "h1",
          "symbol" => "AAPL",
          "quantity" => 10,
          "market_value" => 2000,
          "currency" => "USD"
        },
        {
          "id" => "h2",
          "symbol" => "NEWCO",
          "quantity" => 5,
          "market_value" => 500,
          "currency" => "USD"
        }
      ]
    )

    assert_difference "Holding.where(account: @account).count", 2 do
      SimplefinHoldingsApplyJob.perform_now(@sfa.id)
    end


    # Running again should not create duplicates (external_id uniqueness)
    assert_no_difference "Holding.where(account: @account).count" do
      SimplefinHoldingsApplyJob.perform_now(@sfa.id)
    end

    holdings = @account.holdings.order(:external_id)
    aapl = holdings.find { |h| h.security.ticker == "AAPL" }
    refute_nil aapl
    assert_equal 10, aapl.qty
    assert_equal Money.new(2000, "USD"), aapl.amount_money

    newco_sec = Security.find_by(ticker: "NEWCO")
    refute_nil newco_sec, "should create NEWCO security via resolver when missing"
  end

  test "uses market_value for price and does not confuse value with market_value" do
    # Regression test for GH #1182: some brokerages (Vanguard, Fidelity) include a
    # "value" field that represents cost basis, not market value. The processor must
    # use "market_value" for price derivation and treat "value" as a cost_basis fallback.
    @account.holdings.delete_all

    @sfa.update!(
      raw_holdings_payload: [
        {
          "id" => "h_vanguard",
          "symbol" => "VFIAX",
          "shares" => 50,
          "market_value" => 22626.42,
          "cost_basis" => 22004.40,
          "value" => 22004.40,
          "currency" => "USD"
        }
      ]
    )

    assert_difference "Holding.where(account: @account).count", 1 do
      SimplefinHoldingsApplyJob.perform_now(@sfa.id)
    end

    holding = @account.holdings.find_by(external_id: "simplefin_h_vanguard")
    refute_nil holding

    # Price should be derived from market_value / shares, NOT from value / shares
    expected_price = BigDecimal("22626.42") / BigDecimal("50")
    assert_in_delta expected_price.to_f, holding.price.to_f, 0.01,
      "price should be market_value/qty (#{expected_price}), not value/qty"

    # Amount should reflect market_value, not cost basis
    assert_in_delta 22626.42, holding.amount.to_f, 0.01
  end

  test "falls back to value for cost_basis when cost_basis field is absent" do
    @account.holdings.delete_all

    @sfa.update!(
      raw_holdings_payload: [
        {
          "id" => "h_fallback",
          "symbol" => "FXAIX",
          "shares" => 100,
          "market_value" => 50000,
          "value" => 45000,
          "currency" => "USD"
        }
      ]
    )

    assert_difference "Holding.where(account: @account).count", 1 do
      SimplefinHoldingsApplyJob.perform_now(@sfa.id)
    end

    holding = @account.holdings.find_by(external_id: "simplefin_h_fallback")
    refute_nil holding

    # Price derived from market_value
    assert_in_delta 500.0, holding.price.to_f, 0.01

    # cost_basis should fall back to "value" field (45000)
    assert_in_delta 45000.0, holding.cost_basis.to_f, 0.01
  end
end
