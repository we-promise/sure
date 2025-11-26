require "test_helper"

class SimplefinItem::ImporterPostImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(family: @family, name: "SF Conn", access_url: "https://example.com/access")
    @sync = Sync.create!(syncable: @item)
  end

  test "credit account import updates available_credit when available-balance provided" do
    credit_acct = accounts(:credit_card)

    sfa = @item.simplefin_accounts.create!(
      name: "CC",
      account_id: "sf_cc_1",
      currency: "USD",
      account_type: "credit",
      available_balance: 0
    )
    # Link via legacy association
    credit_acct.update!(simplefin_account_id: sfa.id)

    importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock(), sync: @sync)

    account_data = {
      id: sfa.account_id,
      name: "CC",
      balance: -1200.0, # liabilities often negative from provider
      currency: "USD",
      "available-balance": 5000.0
    }

    # Call private method for focused unit test
    importer.send(:import_account, account_data)

    assert_equal 5000.0, credit_acct.reload.credit_card.available_credit
  end

  test "investment import recalculates cash_balance when holdings payload changes" do
    invest_acct = accounts(:investment)

    sfa = @item.simplefin_accounts.create!(
      name: "Invest",
      account_id: "sf_inv_1",
      currency: "USD",
      account_type: "investment",
      current_balance: 0
    )
    invest_acct.update!(simplefin_account_id: sfa.id)

    importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock(), sync: @sync)

    holdings = [
      { "id" => "h1", "symbol" => "AAPL", "quantity" => 10, "market_value" => 2000, "currency" => "USD", "as_of" => Date.current.to_s },
      { "id" => "h2", "symbol" => "MSFT", "quantity" => 20, "market_value" => 4000, "currency" => "USD", "as_of" => Date.current.to_s }
    ]

    account_data = {
      id: sfa.account_id,
      name: "Invest",
      balance: 10000.0,
      currency: "USD",
      holdings: holdings
    }

    # Prevent the job from running in this unit test; we only care about cash balance recompute
    SimplefinHoldingsApplyJob.expects(:perform_later).once

    importer.send(:import_account, account_data)

    # Cash balance should be total balance (10_000) minus market_value sum (6_000) = 4_000
    assert_equal 4000.0, invest_acct.reload.cash_balance
  end
end
