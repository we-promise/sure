require "test_helper"

class Assistant::Function::GetHoldingsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:investment)
    @fn = Assistant::Function::GetHoldings.new(@user)
  end

  test "excludes positions closed by a newer zero quantity holding" do
    msft = securities(:msft)
    @account.holdings.create!(security: msft, date: 1.day.ago.to_date, qty: 5, price: 400, amount: 2000, currency: "USD")
    @account.holdings.create!(security: msft, date: Date.current, qty: 0, price: 410, amount: 0, currency: "USD")

    tickers = @fn.call("page" => 1)[:holdings].map { |h| h[:ticker] }

    assert_includes tickers, "AAPL"
    assert_not_includes tickers, "MSFT"
  end
end
