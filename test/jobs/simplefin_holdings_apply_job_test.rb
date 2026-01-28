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
end
