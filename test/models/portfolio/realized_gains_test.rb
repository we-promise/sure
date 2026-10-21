require "test_helper"

class Portfolio::RealizedGainsTest < ActiveSupport::TestCase
  include SqlQueryCapture

  setup do
    @family = families(:empty)
    @account = create_account
    @march = Date.new(2026, 3, 10)
    @april = Date.new(2026, 4, 14)
    @period = Period.custom(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 12, 31))
  end

  # Hand-computable: a basis of 100 a share, 2 sold at 150 is a gain of 100,
  # and 1 sold at 130 a month later is 30. The second disposal is in another
  # month so the buckets have to separate rather than merge into one total.
  test "a sale is bucketed in the month it was realised" do
    holding_snapshot account: @account, date: @march, cost_basis: 100
    sell_trade account: @account, date: @march, qty: 2, price: 150
    sell_trade account: @account, date: @april, qty: 1, price: 130

    buckets = realized.buckets

    assert_equal [ Date.new(2026, 3, 1), Date.new(2026, 4, 1) ], buckets.map(&:month)
    assert_equal BigDecimal(100), buckets.first.gains
    assert_equal BigDecimal(0), buckets.first.losses
    assert_equal BigDecimal(30), buckets.second.gains
    assert_equal BigDecimal(130), realized.net
    assert_equal 2, realized.trade_count
  end

  # A transfer out carries the same negative qty as a sale. Nothing was
  # disposed of, so there is no month and no figure, and nothing excluded.
  test "a transfer out is not a realised sale" do
    holding_snapshot account: @account, date: @march, cost_basis: 100
    sell_trade account: @account, date: @march, qty: 2, price: 150, label: "Transfer"

    assert_empty realized.buckets
    assert_equal 0, realized.trade_count
    assert_empty realized.excluded_trades,
                 "a movement that realised nothing is not a disposal this class failed to measure"
  end

  # "Exchange" on a security can dispose of an appreciated asset, so it is not
  # an internal movement for a trade and its gain is reported.
  test "a security exchange is still a disposal" do
    holding_snapshot account: @account, date: @march, cost_basis: 100
    sell_trade account: @account, date: @march, qty: 2, price: 150, label: "Exchange"

    assert_equal BigDecimal(100), realized.net
  end

  # A realised gain is fixed on the day of the sale. Today's rate is
  # deliberately different: if it were used the figure would be 300, not 150.
  test "a foreign currency gain converts at its own trade date" do
    account = create_account(currency: "EUR")
    holding_snapshot account: account, date: @march, cost_basis: 100
    sell_trade account: account, date: @march, qty: 2, price: 150
    set_rate from: "EUR", to: "USD", date: @march, rate: 1.5
    set_rate from: "EUR", to: "USD", date: Date.current, rate: 3.0

    gains = build_gains(account)

    assert_equal BigDecimal(150), gains.net, "100 EUR of gain at the trade date's 1.5, not today's 3.0"
    assert_empty gains.excluded_trades
  end

  # No parity fallback: a gain that cannot be converted is reported, never
  # counted at 1:1. Here it would read 100 at parity.
  test "a gain with no exchange rate for its trade date is excluded and counted" do
    account = create_account(currency: "EUR")
    holding_snapshot account: account, date: @march, cost_basis: 100
    sell_trade account: account, date: @march, qty: 2, price: 150
    set_rate from: "EUR", to: "USD", date: @march - 1, rate: 1.5

    gains = build_gains(account)

    assert_empty gains.buckets, "the previous day's rate is not the trade date's"
    assert_equal({ missing_exchange_rate: 1 }, gains.excluded_trades)
    assert_equal 1, gains.excluded_trade_count
  end

  # Folding this case to 0 drags a total toward zero with nothing to say so.
  test "a sale with no determinable cost basis is excluded and counted" do
    holding_snapshot account: @account, date: @march, cost_basis: nil
    sell_trade account: @account, date: @march, qty: 2, price: 150

    assert_empty realized.buckets
    assert_equal BigDecimal(0), realized.net
    assert_equal({ gain_unknown: 1 }, realized.excluded_trades)
  end

  # A period whose every disposal was unmeasurable has no buckets, and that is
  # exactly the case a caller must not hide.
  test "a period whose only disposals are all excluded still reports itself" do
    holding_snapshot account: @account, date: @march, cost_basis: nil
    sell_trade account: @account, date: @march, qty: 2, price: 150

    assert_empty realized.buckets
    assert realized.any?, "the exclusion must still be reportable"
  end

  test "a portfolio with no disposals at all reports nothing" do
    assert_not realized.any?
    assert_empty realized.excluded_trades
  end

  # `losses` is a positive magnitude and `net` carries the sign.
  test "a disposal below cost is a loss, reported as a magnitude with a negative net" do
    holding_snapshot account: @account, date: @march, cost_basis: 100
    sell_trade account: @account, date: @march, qty: 2, price: 60

    bucket = realized.buckets.sole

    assert_equal BigDecimal(0), bucket.gains
    assert_equal BigDecimal(80), bucket.losses
    assert_equal BigDecimal(-80), bucket.net
    assert_equal BigDecimal(-80), realized.net
  end

  test "gains and losses in one month are reported separately" do
    other = create_security
    holding_snapshot account: @account, date: @march, cost_basis: 100
    holding_snapshot account: @account, date: @march, cost_basis: 100, security: other
    sell_trade account: @account, date: @march, qty: 2, price: 150
    sell_trade account: @account, date: @march, qty: 1, price: 60, security: other

    bucket = realized.buckets.sole

    assert_equal BigDecimal(100), bucket.gains
    assert_equal BigDecimal(40), bucket.losses
    assert_equal BigDecimal(60), bucket.net
    assert_equal 2, bucket.trade_count
  end

  # Trade#realized_gain_loss converts the proceeds into the basis currency
  # before subtracting. A USD account holding a EUR-priced security: 300 EUR
  # of proceeds at 1.5 is 450 USD, less 200 USD of basis, so 250 USD.
  test "a disposal priced in another currency is measured in its basis currency" do
    holding_snapshot account: @account, date: @march, cost_basis: 100
    sell_trade account: @account, date: @march, qty: 2, price: 150, currency: "EUR"
    set_rate from: "EUR", to: "USD", date: @march, rate: 1.5

    assert_equal BigDecimal(250), realized.net
  end

  # Without a rate for the proceeds, Trade#realized_gain_loss gives no figure,
  # and that is reported rather than counted.
  test "a disposal whose proceeds cannot be converted into its basis is excluded" do
    holding_snapshot account: @account, date: @march, cost_basis: 100
    sell_trade account: @account, date: @march, qty: 2, price: 150, currency: "EUR"

    assert_empty realized.buckets
    assert_equal({ gain_unknown: 1 }, realized.excluded_trades)
  end

  # The gain is carried in the HOLDING's currency, not the trade's, so that
  # is the currency converted from. A GBP-priced sale against a EUR basis in a
  # USD family: 300 GBP at 1.2 is 360 EUR, less 200 EUR of basis, so 160 EUR,
  # which at 1.5 is 240 USD. Converting from the trade's GBP at 2.0 would
  # give 320.
  test "a gain converts from the currency its basis is carried in" do
    holding_snapshot account: @account, date: @march, cost_basis: 100, currency: "EUR"
    sell_trade account: @account, date: @march, qty: 2, price: 150, currency: "GBP"
    set_rate from: "GBP", to: "EUR", date: @march, rate: 1.2
    set_rate from: "EUR", to: "USD", date: @march, rate: 1.5
    set_rate from: "GBP", to: "USD", date: @march, rate: 2.0

    assert_equal BigDecimal(240), realized.net
  end

  # Without the preload, each disposal looks up its own holding. Asserting
  # equality rather than a number: the constant is the claim.
  test "the query count does not grow with the number of disposals" do
    seed_disposals(2)
    few = capture_sql_queries { measure_fully(realized) }.size

    seed_disposals(4)
    many = capture_sql_queries { measure_fully(realized) }.size

    assert_equal 6, realized.trade_count, "the fixture must actually grow, or this proves nothing"
    assert_equal few, many, "2 disposals and 6 must cost the same number of queries"
  end

  # The test above prices every disposal in the account's currency, which
  # never needs a rate. A foreign-priced disposal converts its proceeds into
  # the basis currency, and without Trade.preload_exchange_rates that is one
  # rate lookup per disposal. The dates differ so each needs its own rate.
  test "the query count does not grow with foreign-priced disposals" do
    seed_disposals(2, currency: "EUR")
    few = capture_sql_queries { measure_fully(realized) }.size

    seed_disposals(4, currency: "EUR")
    many = capture_sql_queries { measure_fully(realized) }.size

    assert_equal 6, realized.trade_count, "every disposal must be measured, or this proves nothing"
    assert_equal few, many, "2 foreign disposals and 6 must cost the same number of queries"
  end

  # A disabled account stops contributing on its cut-off date.
  test "a disposal after an account's cut-off date does not count" do
    holding_snapshot account: @account, date: @march, cost_basis: 100
    sell_trade account: @account, date: @march, qty: 1, price: 150
    sell_trade account: @account, date: @april, qty: 2, price: 150

    gains = Portfolio::RealizedGains.new(
      accounts: [ @account ], period: @period, currency: "USD", active_until_dates: { @account.id => @march }
    )

    assert_equal BigDecimal(50), gains.net, "the March sale counts and the April one does not"
  end

  test "a disposal outside the period does not count" do
    holding_snapshot account: @account, date: Date.new(2025, 11, 1), cost_basis: 100
    sell_trade account: @account, date: Date.new(2025, 11, 4), qty: 2, price: 150
    sell_trade account: @account, date: @march, qty: 1, price: 150

    assert_equal [ Date.new(2026, 3, 1) ], realized.buckets.map(&:month)
  end

  test "another account's disposals do not count" do
    other = create_account
    holding_snapshot account: other, date: @march, cost_basis: 100
    sell_trade account: other, date: @march, qty: 2, price: 150

    assert_not realized.any?
  end

  private
    def realized
      build_gains(@account)
    end

    def build_gains(account)
      Portfolio::RealizedGains.new(accounts: [ account ], period: @period, currency: "USD")
    end

    # Reads every derived figure, so the capture covers the whole query path.
    def measure_fully(gains)
      gains.buckets
      gains.excluded_trades
      gains.net
    end

    # n securities, each with a stored basis and one sale. A foreign `currency`
    # prices each sale on its own day, with that day's rate into the account's.
    def seed_disposals(count, currency: nil)
      @seeded ||= 0
      count.times do
        security = create_security
        date = @march + (@seeded += 1)
        holding_snapshot account: @account, date: @march, cost_basis: 100, security: security
        sell_trade account: @account, date: date, qty: 1, price: 150, security: security, currency: currency
        set_rate from: currency, to: @account.currency, date: date, rate: 1.5 if currency
      end
    end

    def create_account(currency: "USD")
      @family.accounts.create!(
        name: "Brokerage #{SecureRandom.hex(3)}", balance: 0, cash_balance: 0,
        currency: currency, accountable: Investment.new
      )
    end

    def create_security
      Security.create!(ticker: "RG#{SecureRandom.hex(4)}", name: "Realised gains security")
    end

    def security_under_test
      @security_under_test ||= create_security
    end

    def sell_trade(account:, date:, qty:, price:, currency: nil, label: "Sell", security: nil)
      currency ||= account.currency
      account.entries.create!(
        name: "Sell", date: date, amount: BigDecimal((-qty.abs * price).to_s), currency: currency,
        entryable: Trade.new(
          security: security || security_under_test, qty: -qty.abs, price: price,
          currency: currency, investment_activity_label: label
        )
      )
    end

    # A snapshot with an explicit per-share basis, so a test's gain is
    # hand-computable. `cost_basis: nil` with no buy trades behind it is the
    # case where the basis cannot be determined.
    def holding_snapshot(account:, date:, cost_basis:, security: nil, currency: nil)
      account.holdings.create!(
        security: security || security_under_test, date: date, qty: 5, price: 150,
        amount: BigDecimal(750), currency: currency || account.currency, cost_basis: cost_basis
      )
    end

    def set_rate(from:, to:, date:, rate:)
      ExchangeRate.create!(from_currency: from, to_currency: to, date: date, rate: rate)
    end
end
