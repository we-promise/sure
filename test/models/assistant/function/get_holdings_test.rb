require "test_helper"

class Assistant::Function::GetHoldingsTest < ActiveSupport::TestCase
  include EntriesTestHelper

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

  test "get_holdings leaves out a position whose newest row is zero" do
    msft = securities(:msft)
    @account.holdings.create!(security: msft, date: 1.day.ago.to_date, qty: 5, price: 400, amount: 2000, currency: "USD")
    @account.holdings.find_by!(security: msft, date: Date.current).update!(qty: 0, amount: 0)

    assert_equal [ "AAPL" ], tickers({})
  end

  test "get_holdings reports the same average cost as the holdings page on a provider-linked account" do
    account, account_provider = linked_account

    security = Security.create!(ticker: "REPRO", name: "Repro Security")
    (5.days.ago.to_date..Date.current).each do |date|
      Security::Price.create!(security: security, date: date, price: 400)
    end

    # The provider dates its snapshot yesterday: 40 shares at an average cost of 200.
    account.holdings.create!(
      security: security, date: 1.day.ago.to_date, qty: 40, price: 400, amount: 16000, currency: "USD",
      cost_basis: 200, cost_basis_source: "provider", account_provider: account_provider
    )
    # The imported trades explain only 10 of the 40 shares, so the calculated
    # row the materializer writes for today averages 350.
    create_trade(security, account: account, qty: 10, price: 350, date: 3.days.ago.to_date)
    Holding::Materializer.new(account, strategy: :reverse).materialize_holdings

    page_holding = account.reload.current_holdings.find_by!(security: security)
    tool_holding = @fn.call("page" => 1)[:holdings].find { |holding| holding[:ticker] == "REPRO" }

    assert_equal 200.0, page_holding.avg_cost.amount.to_f
    assert_equal page_holding.avg_cost.amount.to_f, tool_holding[:average_cost]
    assert_equal page_holding.date, tool_holding[:date]
  end

  test "get_holdings converts other currencies to the family currency before ordering and totaling" do
    account, account_provider = linked_account
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.5)
    euro_security = Security.create!(ticker: "EURX", name: "Euro Security")
    dollar_security = Security.create!(ticker: "USDX", name: "Dollar Security")

    # A USD account whose provider snapshot holds one position in EUR.
    account.holdings.create!(
      security: euro_security, date: 1.day.ago.to_date, qty: 10, price: 100, amount: 1000, currency: "EUR",
      account_provider: account_provider
    )
    account.holdings.create!(
      security: dollar_security, date: 1.day.ago.to_date, qty: 10, price: 120, amount: 1200, currency: "USD",
      account_provider: account_provider
    )

    result = @fn.call("page" => 1, "accounts" => [ account.name ])

    assert_equal [ "EURX", "USDX" ], result[:holdings].map { |holding| holding[:ticker] }
    assert_equal Money.new(2700, "USD").format, result[:total_value]
  end

  private

    # An investment account linked to a provider; any provider works, it
    # only makes the holdings provider rows.
    def linked_account
      account = @user.family.accounts.create!(
        name: "Linked Brokerage", balance: 20000, cash_balance: 4000, currency: "USD",
        accountable: Investment.new, owner: @user
      )
      provider_item = @user.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
      provider_account = provider_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
      [ account, AccountProvider.create!(account: account, provider: provider_account) ]
    end

    def tickers(params)
      @fn.call({ "page" => 1 }.merge(params))[:holdings].map { |row| row[:ticker] }.uniq.sort
    end
end
