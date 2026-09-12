require "test_helper"

class SimplefinAccount::Investments::BalanceCalculatorTest < ActiveSupport::TestCase
  test "cash_equivalent? detects configured money market funds" do
    assert SimplefinAccount::Investments::BalanceCalculator.cash_equivalent?(symbol: "spaxx", description: "")
    assert SimplefinAccount::Investments::BalanceCalculator.cash_equivalent?(symbol: "UNKNOWN", description: "Money Market Settlement Fund")
    assert_not SimplefinAccount::Investments::BalanceCalculator.cash_equivalent?(symbol: "AAPL", description: "Apple Inc")
  end
end
