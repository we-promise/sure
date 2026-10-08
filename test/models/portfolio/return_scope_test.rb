require "test_helper"

class Portfolio::ReturnScopeTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = create_portfolio_account(family: @family)
    @day_one = Date.new(2026, 3, 2)
    @day_two = Date.new(2026, 3, 3)
    @period = Period.custom(start_date: @day_one, end_date: @day_two)
  end

  # One point is a position, not a return. Quoting a figure from
  # it would mean inventing an opening value.
  test "an account with one balance day is insufficient" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.insufficient?
    refute scope.supports_time_weighted_return?
    refute scope.supports_money_weighted_return?
  end

  # Without trades or transfers there is no record of what was
  # paid in, so an XIRR over "the flows" would be an XIRR over an empty set
  # dressed up as a measurement.
  test "a valuation tracked account does not support money weighted return" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_200, revaluation: 200
    create_valuation_entry(date: @day_two, amount: 1_200)

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.valuation_tracked?
    assert scope.supports_time_weighted_return?, "the value still changed, and that change is reportable"
    refute scope.supports_money_weighted_return?
    assert_equal "value_return", scope.return_label_key
  end

  test "an account with trades is trade tracked and supports both methods" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000
    buy_trade account: @account, date: @day_two, qty: 2, price: 100

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.trade_tracked?
    assert scope.supports_time_weighted_return?
    assert scope.supports_money_weighted_return?
    assert_equal "time_weighted_return", scope.return_label_key
  end

  test "an account whose only records are external transfers is trade tracked" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_500, cash_flow: 500
    deposit account: @account, date: @day_two, amount: 500

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.trade_tracked?, "a known deposit is enough to know the flows"
    assert scope.supports_money_weighted_return?
  end

  test "balances with no explanation at all are treated as valuation tracked" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.valuation_tracked?,
           "the value change is real and reportable; the flows behind it are not known"
    refute scope.supports_money_weighted_return?
  end

  # An excluded trade is not a record of anything, so it cannot make the
  # account's flows known.
  test "an excluded trade does not make an account trade tracked" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100
    buy_trade(account: @account, date: @day_two, qty: 1, price: 10).update!(excluded: true)

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.valuation_tracked?
    refute scope.supports_money_weighted_return?
  end

  # Trades and valuations are read up to the end of the period, so transfers
  # must be too: a deposit made before the period is still a known flow.
  test "a transfer before the period still marks the account trade tracked" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100
    deposit account: @account, date: @day_one - 10.days, amount: 1_000

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.trade_tracked?
  end

  # `entries.excluded` is nullable and the flow classifier reads NULL as live. A bare
  # `excluded = false` drops such a row.
  test "a deposit with a null excluded flag is a known flow" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_500, cash_flow: 500
    deposit(account: @account, date: @day_two, amount: 500).update_column(:excluded, nil)

    scope = Portfolio::ReturnScope.new(account: @account, period: @period)

    assert scope.trade_tracked?
  end

  # The batch path exists to save queries, not to mean something different.
  # This is the assertion that fails first if it ever drifts.
  test "resolve_all agrees with a directly built scope on every kind" do
    insufficient = @account
    lay_balance account: insufficient, date: @day_one, opening: 1_000, closing: 1_000

    trade_tracked = create_portfolio_account(family: @family)
    lay_balance account: trade_tracked, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: trade_tracked, date: @day_two, opening: 1_000, closing: 1_000
    buy_trade account: trade_tracked, date: @day_two, qty: 2, price: 100

    valuation_tracked = create_portfolio_account(family: @family)
    lay_balance account: valuation_tracked, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: valuation_tracked, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100

    accounts = [ insufficient, trade_tracked, valuation_tracked ]
    resolved = Portfolio::ReturnScope.resolve_all(accounts: accounts, period: @period)

    assert_equal Portfolio::ReturnScope::KINDS.sort, resolved.values.map(&:kind).sort,
                 "the three accounts should cover all three kinds"

    accounts.each do |account|
      direct = Portfolio::ReturnScope.new(account: account, period: @period)

      assert_equal direct.kind, resolved.fetch(account.id).kind, "kind drifted for #{account.name}"
      assert_equal direct.balance_days, resolved.fetch(account.id).balance_days
      assert_equal direct.supports_money_weighted_return?, resolved.fetch(account.id).supports_money_weighted_return?
    end
  end

  # Each account is its own classifier scope: the question is whether money
  # crossed THIS account's boundary. Resolving the set under one shared scope
  # would read this transfer as internal and drop the account to
  # VALUATION_TRACKED, withholding a money-weighted return it should quote.
  test "a transfer to a sibling account in the same set is still external to its own account" do
    sibling = create_portfolio_account(family: @family)

    [ @account, sibling ].each do |account|
      lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
      lay_balance account: account, date: @day_two, opening: 1_000, closing: 1_000
    end

    create_transfer(from_account: @account, to_account: sibling, amount: 500, date: @day_two)

    resolved = Portfolio::ReturnScope.resolve_all(accounts: [ @account, sibling ], period: @period)

    assert resolved.fetch(@account.id).trade_tracked?,
           "the account it left is trade tracked: the flow crossed its own boundary"
    assert resolved.fetch(sibling.id).trade_tracked?,
           "the account it arrived in is trade tracked for the same reason"
  end

  # A GROUP BY returns no row for an account with nothing in the period. Left
  # missing rather than defaulted, `balance_days.zero?` stops being load-bearing
  # at both Performance call sites, where it means "contributes nothing".
  test "an account with no balance rows in the period resolves to zero rather than going missing" do
    empty = create_portfolio_account(family: @family)

    resolved = Portfolio::ReturnScope.resolve_all(accounts: [ empty ], period: @period)

    assert_equal [ empty.id ], resolved.keys
    assert_equal 0, resolved.fetch(empty.id).balance_days
    assert resolved.fetch(empty.id).insufficient?
  end

  # The instance counts balance rows in the account's OWN currency. A batch
  # query grouping over balances alone would count every currency it holds.
  test "balance days do not count rows in another currency" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    @account.balances.create!(
      date: @day_two,
      currency: "EUR",
      balance: 900,
      cash_balance: 900,
      start_cash_balance: 900,
      start_non_cash_balance: 0,
      cash_inflows: 0,
      cash_outflows: 0,
      non_cash_inflows: 0,
      non_cash_outflows: 0,
      net_market_flows: 0,
      cash_adjustments: 0,
      non_cash_adjustments: 0,
      flows_factor: 1
    )

    resolved = Portfolio::ReturnScope.resolve_all(accounts: [ @account ], period: @period)

    assert_equal 1, resolved.fetch(@account.id).balance_days,
                 "only the account's own currency counts"
    assert_equal Portfolio::ReturnScope.new(account: @account, period: @period).balance_days,
                 resolved.fetch(@account.id).balance_days
  end

  # The batch path's actual cost, pinned so a claim about it can be settled by
  # a number. Four round trips: the account load, then the three resolution
  # queries. The account load is not avoidable here -- `resolve_all` returns
  # `ReturnScope` objects that hold the record, and `Portfolio::Performance`
  # carries only ids -- and what the batch path buys is that the four do not
  # grow with the number of accounts.
  test "resolve_all asks the same number of queries however many accounts it is given" do
    second = create_portfolio_account(family: @family)
    third = create_portfolio_account(family: @family)
    [ @account, second, third ].each do |account|
      lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
    end

    one = capture_sql_queries do
      Portfolio::ReturnScope.resolve_all(accounts: Account.where(id: [ @account.id ]), period: @period)
    end
    three = capture_sql_queries do
      Portfolio::ReturnScope.resolve_all(
        accounts: Account.where(id: [ @account.id, second.id, third.id ]), period: @period
      )
    end

    assert_equal 4, one.size, "one account: the account load plus three resolution queries\n#{one.join("\n")}"
    assert_equal one.size, three.size,
                 "three accounts must cost what one does, or the batch path buys nothing\n#{three.join("\n")}"
  end

  test "resolve_all over no accounts asks nothing" do
    queries = capture_sql_queries do
      assert_empty Portfolio::ReturnScope.resolve_all(accounts: [], period: @period)
    end

    assert_empty queries, "an empty set must not reach the database at all"
  end

  private
    def create_valuation_entry(date:, amount:)
      @account.entries.create!(
        name: "Valuation",
        date: date,
        amount: amount,
        currency: @account.currency,
        entryable: Valuation.new(kind: "reconciliation")
      )
    end
end
