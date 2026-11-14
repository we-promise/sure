require "test_helper"

class Assistant::Function::GetHoldingsTest < ActiveSupport::TestCase
  setup do

    @user = users(:family_admin)
    @fn = Assistant::Function::GetHoldings.new(@user)
    @account = accounts(:investment)
    # The fixtures hold only AAPL, so a second ticker on the same account is
    # what tells a filter from no filter.
    @account.holdings.create!(security: securities(:msft), date: Date.current, qty: 3, price: 400, amount: 1200, currency: "USD")
  end

  test "get_holdings filters by security ticker" do
    assert_equal [ "AAPL" ], tickers("securities" => [ "AAPL" ])
    assert_equal [ "MSFT" ], tickers("securities" => [ "MSFT" ])
    assert_equal 1, @fn.call("page" => 1, "securities" => [ "MSFT" ])[:total_results]
  end

  test "excludes positions closed by a newer zero quantity holding" do
    msft = securities(:msft)
    @account.holdings.create!(security: msft, date: 1.day.ago.to_date, qty: 5, price: 400, amount: 2000, currency: "USD")
    @account.holdings.create!(security: msft, date: Date.current, qty: 0, price: 410, amount: 0, currency: "USD")

    tickers = @fn.call("page" => 1)[:holdings].map { |h| h[:ticker] }

    assert_includes tickers, "AAPL"
    assert_not_includes tickers, "MSFT"
  end
  
  test "get_holdings security filter for a ticker nobody holds returns nothing" do
    assert_empty tickers("securities" => [ "NOPE" ])
  end

  test "get_holdings security filter does not reach another user's private account" do
    private_account = @user.family.accounts.create!(name: "Member Brokerage", accountable: Investment.new, balance: 0, currency: "USD", owner: users(:family_member))
    hidden = private_account.holdings.create!(security: securities(:aapl), date: Date.current, qty: 9, price: 200, amount: 1800, currency: "USD")

    rows = @fn.call("page" => 1, "securities" => [ "AAPL" ])[:holdings]

    assert_includes rows.map { |row| row[:account] }, @account.name, "the user's own AAPL went too"
    assert_not_includes rows.map { |row| row[:account] }, hidden.account.name
  end

  test "get_holdings without a security filter is unchanged" do
    assert_equal [ "AAPL", "MSFT" ], tickers({})
  end

  private

    def tickers(params)
      @fn.call({ "page" => 1 }.merge(params))[:holdings].map { |row| row[:ticker] }.uniq.sort
    end
end
