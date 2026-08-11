require "test_helper"

class Holding::CashEquivalentBackfillTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment)
    @spaxx = Security.find_or_create_by!(ticker: "SPAXX") do |security|
      security.name = "Fidelity Government Money Market Fund"
    end
    @stock = securities(:aapl)
  end

  test "marks existing SnapTrade holdings with explicit provider cash_equivalent flag" do
    snaptrade_account = snaptrade_accounts(:fidelity_401k)
    AccountProvider.create!(account: @account, provider: snaptrade_account)
    snaptrade_account.update!(
      raw_holdings_payload: [
        {
          "symbol" => {
            "symbol" => { "symbol" => "SPAXX", "description" => "Fidelity Government Money Market Fund" }
          },
          "units" => "100",
          "price" => "1.00",
          "currency" => "USD",
          "cash_equivalent" => true
        }
      ]
    )

    holding = @account.holdings.create!(
      security: @spaxx,
      provider_security: @spaxx,
      date: Date.current,
      qty: 100,
      price: 1,
      amount: 100,
      currency: "USD",
      cash_equivalent: false
    )

    result = Holding::CashEquivalentBackfill.run

    assert_equal 1, result.snaptrade_holdings
    assert holding.reload.cash_equivalent?
  end

  test "marks existing Plaid holdings from stored security metadata" do
    plaid_account = plaid_accounts(:one)
    AccountProvider.create!(account: @account, provider: plaid_account)
    plaid_account.update!(
      raw_holdings_payload: {
        "securities" => [
          {
            "security_id" => "sec_spaxx",
            "ticker_symbol" => "SPAXX",
            "type" => "mutual fund",
            "is_cash_equivalent" => true
          }
        ]
      }
    )

    holding = @account.holdings.create!(
      security: @spaxx,
      provider_security: @spaxx,
      date: Date.current,
      qty: 100,
      price: 1,
      amount: 100,
      currency: "USD",
      cash_equivalent: false
    )

    result = Holding::CashEquivalentBackfill.run

    assert_equal 1, result.plaid_holdings
    assert holding.reload.cash_equivalent?
  end

  test "marks existing SimpleFIN holdings using stored holding id and money market detector" do
    item = SimplefinItem.create!(
      family: families(:dylan_family),
      name: "SimpleFIN",
      access_url: "https://bridge.simplefin.org/simplefin/access"
    )
    simplefin_account = SimplefinAccount.create!(
      simplefin_item: item,
      name: "Fidelity",
      account_id: "simplefin-backfill-account",
      currency: "USD",
      account_type: "investment",
      current_balance: 1000,
      raw_holdings_payload: [
        {
          "id" => "holding-spaxx",
          "symbol" => "SPAXX",
          "description" => "Fidelity Government Money Market Fund",
          "currency" => "USD"
        }
      ]
    )
    AccountProvider.create!(account: @account, provider: simplefin_account)

    holding = @account.holdings.create!(
      security: @spaxx,
      provider_security: @spaxx,
      external_id: "simplefin_holding-spaxx",
      date: Date.current,
      qty: 100,
      price: 1,
      amount: 100,
      currency: "USD",
      cash_equivalent: false
    )

    result = Holding::CashEquivalentBackfill.run

    assert_equal 1, result.simplefin_holdings
    assert holding.reload.cash_equivalent?
  end

  test "does not mark holdings without provider cash-equivalent signals" do
    snaptrade_account = snaptrade_accounts(:fidelity_401k)
    AccountProvider.create!(account: @account, provider: snaptrade_account)
    snaptrade_account.update!(
      raw_holdings_payload: [
        {
          "symbol" => {
            "symbol" => { "symbol" => @stock.ticker, "description" => @stock.name }
          },
          "units" => "10",
          "price" => "150.00",
          "currency" => "USD"
        }
      ]
    )

    holding = @account.holdings.create!(
      security: @stock,
      provider_security: @stock,
      date: Date.current,
      qty: 10,
      price: 150,
      amount: 1500,
      currency: "USD",
      cash_equivalent: false
    )

    result = Holding::CashEquivalentBackfill.run

    assert_equal 0, result.total_holdings
    assert_not holding.reload.cash_equivalent?
  end
end
