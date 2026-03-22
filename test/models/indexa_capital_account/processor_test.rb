# frozen_string_literal: true

require "test_helper"

class IndexaCapitalAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = indexa_capital_items(:configured_with_token)
    @indexa_capital_account = indexa_capital_accounts(:mutual_fund)

    @account = @family.accounts.create!(
      name: "Test Investment",
      balance: 10000,
      currency: "EUR",
      accountable: Investment.new
    )

    @indexa_capital_account.ensure_account_provider!(@account)
    @indexa_capital_account.reload
  end

  # ==========================================================================
  # Processor tests
  # ==========================================================================

  test "processor initializes with indexa_capital_account" do
    processor = IndexaCapitalAccount::Processor.new(@indexa_capital_account)
    assert_not_nil processor
  end

  test "processor skips processing when no linked account" do
    unlinked = indexa_capital_accounts(:pension_plan)

    processor = IndexaCapitalAccount::Processor.new(unlinked)
    assert_nothing_raised { processor.process }
  end

  test "processor updates account balance from holdings value" do
    @indexa_capital_account.update!(
      current_balance: 38905.21,
      raw_holdings_payload: [
        {
          "amount" => 16333.96,
          "titles" => 32.26,
          "price" => 506.32,
          "instrument" => { "identifier" => "IE00BFPM9V94", "name" => "Vanguard US 500" }
        },
        {
          "amount" => 10759.05,
          "titles" => 40.34,
          "price" => 266.71,
          "instrument" => { "identifier" => "IE00BFPM9L96", "name" => "Vanguard European" }
        }
      ]
    )

    @account.update!(balance: 0)

    processor = IndexaCapitalAccount::Processor.new(@indexa_capital_account)
    processor.process

    @account.reload
    assert_in_delta 27093.01, @account.balance.to_f, 0.01
  end

  # ==========================================================================
  # HoldingsProcessor tests
  # ==========================================================================

  test "holdings processor creates holdings from fiscal-results payload" do
    @indexa_capital_account.update!(raw_holdings_payload: [
      {
        "amount" => 16333.96,
        "titles" => 32.26,
        "price" => 506.32,
        "cost_price" => 390.60,
        "instrument" => {
          "identifier" => "IE00BFPM9V94",
          "name" => "Vanguard US 500 Stk Idx Eur -Ins Plus",
          "isin_code" => "IE00BFPM9V94"
        }
      }
    ])

    processor = IndexaCapitalAccount::HoldingsProcessor.new(@indexa_capital_account)

    assert_difference "@account.holdings.count", 1 do
      processor.process
    end

    holding = @account.holdings.order(created_at: :desc).first
    assert_equal "IE00BFPM9V94", holding.security.ticker
    assert_equal 32.26, holding.qty.to_f
  end

  test "holdings processor skips entries without instrument identifier" do
    @indexa_capital_account.update!(raw_holdings_payload: [
      { "amount" => 100, "titles" => 1, "price" => 100, "instrument" => {} }
    ])

    processor = IndexaCapitalAccount::HoldingsProcessor.new(@indexa_capital_account)
    assert_nothing_raised { processor.process }
  end

  test "holdings processor handles empty payload" do
    @indexa_capital_account.update!(raw_holdings_payload: [])

    processor = IndexaCapitalAccount::HoldingsProcessor.new(@indexa_capital_account)
    assert_nothing_raised { processor.process }
  end
end
