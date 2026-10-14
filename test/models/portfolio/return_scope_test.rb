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
  # The batch path reads its own SQL for transfers, so the history rules the
  # instance follows are asserted on it too: a transfer from before the period
  # is known, and an excluded one is not a record of anything.
  test "resolve_all reads transfer history as the instance does" do
    earlier = create_portfolio_account(family: @family)
    lay_balance account: earlier, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: earlier, date: @day_two, opening: 1_000, closing: 1_000
    deposit account: earlier, date: @day_one - 10.days, amount: 1_000

    excluded = create_portfolio_account(family: @family)
    lay_balance account: excluded, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: excluded, date: @day_two, opening: 1_000, closing: 1_000
    deposit(account: excluded, date: @day_one, amount: 1_000).update!(excluded: true)

    resolved = Portfolio::ReturnScope.resolve_all(accounts: [ earlier, excluded ], period: @period)

    assert resolved.fetch(earlier.id).trade_tracked?, "a transfer before the period is still a known flow"
    assert resolved.fetch(excluded.id).valuation_tracked?, "an excluded transfer records nothing"
  end

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

  # An account's cut-off ends its contribution: Portfolio::DailyReturns drops
  # every row after it. Two rows in the period with the second past the cut-off
  # leave ONE day the series can use, and one day is a position, not a return.
  test "a cut-off that leaves one balance day in the window is insufficient" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100

    uncut = Portfolio::ReturnScope.new(account: @account, period: @period)
    cut = Portfolio::ReturnScope.new(account: @account, period: @period, active_until_date: @day_one)

    assert_equal 2, uncut.balance_days, "the fixture must have two rows in the period"
    assert_equal 1, cut.balance_days
    assert cut.insufficient?
  end

  # The batch path keys the cut-offs by account, as DailyReturns does, and must
  # read each account's own -- not one shared date, and not none.
  test "resolve_all counts balance days only up to each account's own cut-off" do
    cut = @account
    uncut = create_portfolio_account(family: @family)
    nil_cut = create_portfolio_account(family: @family)
    [ cut, uncut, nil_cut ].each do |account|
      lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
      lay_balance account: account, date: @day_two, opening: 1_000, closing: 1_000
    end

    resolved = Portfolio::ReturnScope.resolve_all(
      accounts: [ cut, uncut, nil_cut ], period: @period,
      active_until_dates: { cut.id => @day_one, nil_cut.id => nil }
    )

    assert_equal 1, resolved.fetch(cut.id).balance_days
    assert resolved.fetch(cut.id).insufficient?
    assert_equal 2, resolved.fetch(uncut.id).balance_days, "an account with no cut-off keeps every row"
    assert_equal 2, resolved.fetch(nil_cut.id).balance_days, "a nil cut-off means none, as DailyReturns reads it"
    assert_equal Portfolio::ReturnScope.new(account: cut, period: @period, active_until_date: @day_one).balance_days,
                 resolved.fetch(cut.id).balance_days, "the batch and instance paths agree"
  end

  test "resolve_all with cut-offs asks no more queries than without" do
    second = create_portfolio_account(family: @family)
    [ @account, second ].each do |account|
      lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
    end

    queries = capture_sql_queries do
      Portfolio::ReturnScope.resolve_all(
        accounts: Account.where(id: [ @account.id, second.id ]), period: @period,
        active_until_dates: { @account.id => @day_one, second.id => @day_two }
      )
    end

    assert_equal 4, queries.size, "cut-offs are part of the balance query, not one more per account\n#{queries.join("\n")}"
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

  # The cut-off ends the account's contribution to the series, so it ends the
  # history every tracking check reads, not just the balance days. A trade
  # dated after it records a flow the series never sees; counted, it would make
  # an account trade tracked on the strength of a day DailyReturns drops.
  #
  # Each case below is measured against the same account with no cut-off, so
  # the assertion is the cut-off's effect rather than the fixture's, and each
  # is asserted on the instance and on the batch path.
  test "a trade after the cut-off does not make the account trade tracked" do
    lay_two_days_before_the_cut_off
    buy_trade account: @account, date: @day_three, qty: 2, price: 100

    assert_kinds :trade_tracked, cut_off: nil, message: "with no cut-off the trade is a known flow"
    assert_kinds :valuation_tracked, cut_off: @day_two, message: "the trade falls after the cut-off"
  end

  test "an external transfer after the cut-off does not make the account trade tracked" do
    lay_two_days_before_the_cut_off
    deposit account: @account, date: @day_three, amount: 500

    assert_kinds :trade_tracked, cut_off: nil, message: "with no cut-off the deposit is a known flow"
    assert_kinds :valuation_tracked, cut_off: @day_two, message: "the deposit falls after the cut-off"
  end

  # `kind` cannot show this one: an account with neither trades nor transfers
  # is valuation tracked whether or not a valuation explains its balances. The
  # predicate is the only place the read is visible, so the test reads it.
  test "a valuation after the cut-off is not read as the account's history" do
    lay_two_days_before_the_cut_off
    create_valuation_entry(date: @day_three, amount: 1_000)

    assert_equal [ true, true ], valuations_read(cut_off: nil), "with no cut-off the valuation is read"
    assert_equal [ false, false ], valuations_read(cut_off: @day_two), "the valuation falls after the cut-off"
  end

  # The other side of the boundary: the cut-off day is the last day the account
  # contributes, so activity on it still counts.
  test "activity on or before the cut-off still counts" do
    lay_two_days_before_the_cut_off
    buy_trade account: @account, date: @day_two, qty: 2, price: 100

    assert_kinds :trade_tracked, cut_off: @day_two, message: "a trade on the cut-off day is inside it"

    transfer_only = create_portfolio_account(family: @family)
    lay_two_days_before_the_cut_off(transfer_only)
    deposit account: transfer_only, date: @day_one, amount: 500

    assert_kinds :trade_tracked, cut_off: @day_two, account: transfer_only,
                 message: "a deposit before the cut-off is inside it"

    valued = create_portfolio_account(family: @family)
    lay_two_days_before_the_cut_off(valued)
    create_valuation_entry(date: @day_two, amount: 1_000, account: valued)

    assert_equal [ true, true ], valuations_read(cut_off: @day_two, account: valued),
                 "a valuation on the cut-off day is inside it"
  end

  # A cut-off is a bound, never an extension: one later than the period end
  # still stops the read at the period end.
  test "a cut-off after the period does not read history past the period end" do
    lay_two_days_before_the_cut_off
    buy_trade account: @account, date: @day_three + 5.days, qty: 2, price: 100

    assert_kinds :valuation_tracked, cut_off: @day_three + 10.days,
                 message: "the trade is after the period, so the cut-off cannot bring it in"

    deposited = create_portfolio_account(family: @family)
    lay_two_days_before_the_cut_off(deposited)
    deposit account: deposited, date: @day_three + 5.days, amount: 500

    assert_kinds :valuation_tracked, cut_off: @day_three + 10.days, account: deposited,
                 message: "the deposit is after the period, so the cut-off cannot bring it in"

    valued = create_portfolio_account(family: @family)
    lay_two_days_before_the_cut_off(valued)
    create_valuation_entry(date: @day_three + 5.days, amount: 1_000, account: valued)

    assert_equal [ false, false ], valuations_read(cut_off: @day_three + 10.days, account: valued),
                 "the valuation is after the period, so the cut-off cannot bring it in"
  end

  # Every test here counts rows laid by `lay_balance`, so the builder's own
  # arithmetic check has to hold at the precision the rows are stored at.
  # These components add up as given, but `balances` keeps four decimal
  # places: stored, each 0.00005 becomes 0.0001 and the row's end_balance is
  # 0.0002 against a balance of 0.0001.
  test "the balance builder refuses an amount finer than balances store" do
    error = assert_raises(ArgumentError) do
      lay_balance account: @account, date: @day_one, opening: "0.00005", closing: "0.0001", cash_flow: "0.00005"
    end

    assert_match "finer than the 4 decimal places", error.message
    assert_empty @account.balances.reload, "nothing is written for a refused day"

    lay_balance account: @account, date: @day_one, opening: "0.0001", closing: "0.0002", cash_flow: "0.0001"
    assert_equal BigDecimal("0.0002"), @account.balances.reload.sole.end_balance,
                 "four decimal places is the stored scale and is accepted"
  end

  private
    # Two balance days in a three-day period, both on or before a cut-off at
    # day two, so the cut-off leaves the account with a return (two days) and
    # only the activity laid after it is in question.
    def lay_two_days_before_the_cut_off(account = @account)
      @day_three = @day_two + 1.day
      @period = Period.custom(start_date: @day_one, end_date: @day_three)
      lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
      lay_balance account: account, date: @day_two, opening: 1_000, closing: 1_000
    end

    # [instance, batch] for one account under one cut-off.
    def scopes_for(account, cut_off)
      [
        Portfolio::ReturnScope.new(account: account, period: @period, active_until_date: cut_off),
        Portfolio::ReturnScope.resolve_all(
          accounts: [ account ], period: @period, active_until_dates: { account.id => cut_off }
        ).fetch(account.id)
      ]
    end

    def assert_kinds(expected, cut_off:, message:, account: @account)
      instance, batch = scopes_for(account, cut_off)

      assert_equal 2, instance.balance_days, "the cut-off must leave two balance days, or the kind is insufficient for another reason"
      assert_equal expected, instance.kind, "instance: #{message}"
      assert_equal expected, batch.kind, "batch: #{message}"
    end

    def valuations_read(cut_off:, account: @account)
      scopes_for(account, cut_off).map { |scope| scope.send(:valuations?) }
    end

    def create_valuation_entry(date:, amount:, account: @account)
      account.entries.create!(
        name: "Valuation",
        date: date,
        amount: amount,
        currency: account.currency,
        entryable: Valuation.new(kind: "reconciliation")
      )
    end
end
