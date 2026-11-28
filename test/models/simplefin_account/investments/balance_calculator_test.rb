require "test_helper"

class SimplefinAccount::Investments::BalanceCalculatorTest < ActiveSupport::TestCase
  [ nil, [] ].each do |holdings|
    test "cash respects #{holdings.inspect} saved holdings alongside a legacy raw snapshot" do
      source = SimplefinAccount.new(current_balance: 200, raw_holdings_payload: holdings,
        raw_payload: { holdings: [ { symbol: "AAPL", market_value: "100" } ] })

      cash = SimplefinAccount::Investments::BalanceCalculator.new(source).cash_balance

      assert_equal holdings.nil? ? 100 : 200, cash
    end
  end
end
