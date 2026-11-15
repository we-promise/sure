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

    # The row the old query picked. Without it this test would pass without
    # testing anything.
    calculated_holding = account.holdings.find_by!(security: security, date: Date.current, account_provider_id: nil)
    assert_equal 350.0, calculated_holding.avg_cost.amount.to_f

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

  test "get_holdings counts a holding whose currency has no rate as zero and lists it last" do
    account, account_provider = linked_account
    unrated_security = Security.create!(ticker: "JPYX", name: "Yen Security")
    dollar_security = Security.create!(ticker: "USDX", name: "Dollar Security")

    # No JPY rate is stored, so the yen row can't be converted.
    account.holdings.create!(
      security: unrated_security, date: 1.day.ago.to_date, qty: 10, price: 500, amount: 5000, currency: "JPY",
      account_provider: account_provider
    )
    account.holdings.create!(
      security: dollar_security, date: 1.day.ago.to_date, qty: 10, price: 120, amount: 1200, currency: "USD",
      account_provider: account_provider
    )

    result = @fn.call("page" => 1, "accounts" => [ account.name ])

    assert_equal [ "USDX", "JPYX" ], result[:holdings].map { |holding| holding[:ticker] }
    assert_equal [ 5000.0, "JPY" ], result[:holdings].last.values_at(:amount, :currency)
    assert_equal Money.new(1200, "USD").format, result[:total_value]
  end

  test "get_holdings converts accounts in different currencies to the family currency" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.5)
    euro_account = investment_account("Euro Brokerage", currency: "EUR")
    dollar_account = investment_account("Dollar Brokerage", currency: "USD")
    euro_account.holdings.create!(security: securities(:aapl), date: Date.current, qty: 5, price: 200, amount: 1000, currency: "EUR")
    dollar_account.holdings.create!(security: securities(:msft), date: Date.current, qty: 3, price: 400, amount: 1200, currency: "USD")

    result = @fn.call("page" => 1, "accounts" => [ euro_account.name, dollar_account.name ])

    assert_equal [ euro_account.name, dollar_account.name ], result[:holdings].map { |holding| holding[:account] }
    assert_equal Money.new(2700, "USD").format, result[:total_value]
  end

  test "get_holdings keeps the same order across pages" do
    Assistant::Function::GetHoldings.stubs(:default_page_size).returns(2)
    account = investment_account("Paged Brokerage", currency: "USD")
    largest, *tied = [ 300, 200, 200 ].each_with_index.map do |amount, index|
      security = Security.create!(ticker: "PAGE#{index}", name: "Paged Security #{index}")
      account.holdings.create!(security: security, date: Date.current, qty: 1, price: amount, amount: amount, currency: "USD")
    end
    # Equal amounts are ordered by id, so a tie can't land on both pages or on neither.
    expected = [ largest, *tied.sort_by(&:id) ].map(&:ticker)

    first_page = @fn.call("page" => 1, "accounts" => [ account.name ])
    second_page = @fn.call("page" => 2, "accounts" => [ account.name ])

    assert_equal expected.first(2), first_page[:holdings].map { |holding| holding[:ticker] }
    assert_equal expected.last(1), second_page[:holdings].map { |holding| holding[:ticker] }
    assert_equal [ 3, 2, 2 ], second_page.values_at(:total_results, :total_pages, :page)
    assert_equal [ Money.new(700, "USD").format ] * 2, [ first_page[:total_value], second_page[:total_value] ]
  end

  test "get_holdings reads linked and manual accounts in one family each by their own rule" do
    account, account_provider = linked_account
    security = Security.create!(ticker: "LINKED", name: "Linked Security")
    account.holdings.create!(
      security: security, date: 1.day.ago.to_date, qty: 40, price: 400, amount: 16000, currency: "USD",
      account_provider: account_provider
    )
    # A calculated row dated today. The linked account reports its provider row instead.
    account.holdings.create!(security: security, date: Date.current, qty: 10, price: 410, amount: 4100, currency: "USD")

    rows = @fn.call("page" => 1)[:holdings].index_by { |holding| holding[:ticker] }

    assert_equal [ "AAPL", "LINKED", "MSFT" ], rows.keys.sort
    assert_equal [ 40.0, 1.day.ago.to_date ], rows["LINKED"].values_at(:quantity, :date)
    # The manual account reports each security's newest row: today's AAPL, not yesterday's.
    assert_equal [ 2150.0, Date.current ], rows["AAPL"].values_at(:amount, :date)
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

    def investment_account(name, currency:)
      @user.family.accounts.create!(name: name, balance: 0, currency: currency, accountable: Investment.new, owner: @user)
    end

    def tickers(params)
      @fn.call({ "page" => 1 }.merge(params))[:holdings].map { |row| row[:ticker] }.uniq.sort
    end
end
