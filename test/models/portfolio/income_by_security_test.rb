require "test_helper"

# Income attributed to a security, and the bucket for the income that cannot be.
#
# The daily rows are scope-wide, so attribution needs its own read of the
# entries. What these tests hold it to is the property that makes the table
# honest: whatever is attributed plus whatever is not is the total the daily
# rows (and so the bars above the table, and the drivers table) report -- for
# every shape a dividend can be stored in.
class Portfolio::IncomeBySecurityTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper

  setup do
    @family = families(:empty) # USD
    @account = create_portfolio_account(family: @family)
    @aapl = securities(:aapl)
    @msft = securities(:msft)
    @mar = Date.new(2026, 3, 2)
    @last_day = Date.new(2026, 4, 2)
  end

  # The three places a security can be recorded, and the one where it cannot.
  # A Trade carries it as a column; a Transaction only when the provider put it
  # in `extra`, flat (Trading212) or nested (SimpleFIN).
  test "every shape that records a security is attributed to it" do
    income_trade account: @account, date: @mar, amount: 30, security: @aapl
    income_transaction account: @account, date: @mar + 1, amount: 12.5, extra: { "security_id" => @aapl.id }
    income_transaction account: @account, date: @mar + 2, amount: 7, extra: { "security" => { "id" => @msft.id } }
    lay_flat_balances cash_by_date: { @mar => 30, @mar + 1 => 12.5, @mar + 2 => 7 }

    by_security = income_by_security

    assert_equal BigDecimal("42.5"), by_security.amount_for(@aapl.id), "the Trade and the flat Transaction both belong to AAPL"
    assert_equal BigDecimal(7), by_security.amount_for(@msft.id), "the nested payload is read too"
    assert_equal BigDecimal(0), by_security.unattributed
  end

  # The case the section's whole design exists for. A Transaction-shaped
  # dividend with no security counts toward the period's income, so a table that
  # left it out would sum to less than the chart above it.
  test "a dividend that records no security is unattributed, not dropped" do
    income_trade account: @account, date: @mar, amount: 30, security: @aapl
    income_transaction account: @account, date: @mar + 1, amount: 12.5
    lay_flat_balances cash_by_date: { @mar => 30, @mar + 1 => 12.5 }

    by_security = income_by_security

    assert_equal BigDecimal(30), by_security.amount_for(@aapl.id)
    assert_equal BigDecimal("12.5"), by_security.unattributed
    assert_equal by_security.total, by_security.rows.sum(BigDecimal(0), &:amount) + by_security.unattributed,
                 "attributed plus unattributed is the total, by construction"
  end

  # UUIDs compare as text here, and a provider is free to send them upper-case.
  # Two spellings of one id must be one security, not a row and a remainder.
  test "an upper-case id is the same security" do
    income_trade account: @account, date: @mar, amount: 30, security: @aapl
    income_transaction account: @account, date: @mar + 1, amount: 5, extra: { "security_id" => @aapl.id.upcase }
    lay_flat_balances cash_by_date: { @mar => 30, @mar + 1 => 5 }

    by_security = income_by_security

    assert_equal BigDecimal(35), by_security.amount_for(@aapl.id)
    assert_equal BigDecimal(0), by_security.unattributed
  end

  # A provider can record an id this install has no Security for. It cannot be
  # named, so it is unattributed -- not a row with a missing security.
  test "an id that matches no security is unattributed" do
    income_transaction account: @account, date: @mar, amount: 9, extra: { "security_id" => SecureRandom.uuid }
    income_transaction account: @account, date: @mar + 1, amount: 4, extra: { "security_id" => "not-a-uuid" }
    lay_flat_balances cash_by_date: { @mar => 9, @mar + 1 => 4 }

    by_security = income_by_security

    assert_empty by_security.rows
    assert_equal BigDecimal(13), by_security.unattributed
    assert_equal BigDecimal(13), by_security.total
  end

  # Fees and contributions share the entries table with income. Only rows the
  # classifier calls income may be attributed, or a fee on AAPL would read as AAPL income.
  test "a fee on a security is not income from it" do
    income_trade account: @account, date: @mar, amount: 30, security: @aapl
    # Both shapes of a fee that NAMES the security, since a fee with none is
    # never attributed and would pass whether or not fees were filtered out.
    @account.entries.create!(
      name: "Fee", date: @mar, amount: 4, currency: "USD",
      entryable: Trade.new(security: @aapl, qty: 0, price: 0, currency: "USD", investment_activity_label: "Fee")
    )
    @account.entries.create!(
      name: "Fee", date: @mar + 1, amount: 2, currency: "USD",
      entryable: Transaction.new(kind: "standard", investment_activity_label: "Fee", extra: { "security_id" => @aapl.id })
    )
    deposit account: @account, date: @mar + 2, amount: 100
    lay_flat_balances cash_by_date: { @mar => 26, @mar + 1 => -2, @mar + 2 => 100 }

    by_security = income_by_security

    assert_equal BigDecimal(30), by_security.amount_for(@aapl.id)
    assert_equal BigDecimal(30), by_security.total
    assert_equal BigDecimal(0), by_security.unattributed
  end

  # A reversal with no security recorded makes the unattributed remainder
  # NEGATIVE. That is arithmetically what happened -- income was clawed back and
  # nothing says from which security -- and it keeps the table adding up to the
  # total, so it is shown as it is rather than clamped to zero or hidden. Pinned
  # so that it stays a decision and does not become an accident of subtraction.
  test "a reversal with no security makes the unattributed remainder negative, and the table still adds up" do
    income_trade account: @account, date: @mar, amount: 30, security: @aapl
    income_transaction account: @account, date: @mar + 1, amount: -8
    lay_flat_balances cash_by_date: { @mar => 30, @mar + 1 => -8 }

    by_security = income_by_security

    assert_equal BigDecimal(30), by_security.amount_for(@aapl.id)
    assert_equal BigDecimal(-8), by_security.unattributed
    assert_equal BigDecimal(22), by_security.total
    assert_equal by_security.total, by_security.rows.sum(BigDecimal(0), &:amount) + by_security.unattributed
    assert by_security.any?
  end

  test "rows are largest first, and ties are broken by ticker" do
    income_trade account: @account, date: @mar, amount: 5, security: @msft
    income_trade account: @account, date: @mar + 1, amount: 5, security: @aapl
    income_trade account: @account, date: @mar + 2, amount: 20, security: security_under_test
    lay_flat_balances cash_by_date: { @mar => 5, @mar + 1 => 5, @mar + 2 => 20 }

    assert_equal [ security_under_test.ticker, "AAPL", "MSFT" ], income_by_security.rows.map { |row| row.security.ticker }
  end

  # Dates are inclusive on both ends, like every other window in the daily rows.
  test "income outside the period is not attributed" do
    income_trade account: @account, date: @mar - 40, amount: 99, security: @aapl
    income_trade account: @account, date: @mar, amount: 30, security: @aapl
    lay_flat_balances cash_by_date: { @mar => 30 }

    assert_equal BigDecimal(30), income_by_security.amount_for(@aapl.id)
  end

  # The same conversion the bars use: the previous day's rate. The rate on
  # the payment day and every later day is different, so converting at either
  # reads 20 rather than 15.
  test "a foreign currency dividend is converted exactly as the daily rows convert it" do
    eur = create_portfolio_account(family: @family, currency: "EUR")
    income_trade account: eur, date: @mar, amount: 10, security: @aapl
    (@mar - 1..@last_day).each do |date|
      lay_balance account: eur, date: date, opening: 1_000 + (date > @mar ? 10 : 0),
                  closing: 1_000 + (date >= @mar ? 10 : 0), cash_flow: date == @mar ? 10 : 0
      set_rate from: "EUR", to: "USD", date: date, rate: date == @mar - 1 ? 1.5 : 2.0
    end

    returns = Portfolio::DailyReturns.new(account_ids: [ eur.id ], currency: "USD", period: period)
    by_security = Portfolio::IncomeBySecurity.new(amounts: returns.income_by_security, total: Portfolio::Income.new(returns).total)

    assert_equal BigDecimal(15), by_security.amount_for(@aapl.id)
    assert_equal BigDecimal(15), by_security.total
  end

  # A money amount in a currency with no rate cannot be converted and is
  # dropped by the daily rows (rate_missing? reports it). Attribution must drop it the
  # same way, or the table would hold a row the total does not.
  test "a dividend that cannot be converted is left out of both the total and the table" do
    eur = create_portfolio_account(family: @family, currency: "EUR")
    income_trade account: eur, date: @mar, amount: 10, security: @aapl
    lay_balance account: eur, date: @mar - 1, opening: 1_000, closing: 1_000
    lay_balance account: eur, date: @mar, opening: 1_000, closing: 1_010, cash_flow: 10

    returns = Portfolio::DailyReturns.new(account_ids: [ eur.id ], currency: "USD", period: period)

    assert_equal BigDecimal(0), Portfolio::Income.new(returns).total
    assert_empty returns.income_by_security
  end

  test "the amounts a Hash carries survive the cache round trip" do
    income_trade account: @account, date: @mar, amount: 30, security: @aapl
    lay_flat_balances cash_by_date: { @mar => 30 }

    amounts = Marshal.load(Marshal.dump(Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id ], period: period
    ).income[:by_security]))

    assert_equal({ @aapl.id.to_s => BigDecimal(30) }, amounts)
  end

  private
    def period
      Period.custom(start_date: @mar - 1, end_date: @last_day)
    end

    def income_by_security
      returns = Portfolio::DailyReturns.new(account_ids: [ @account.id ], currency: @family.currency, period: period)

      Portfolio::IncomeBySecurity.new(amounts: returns.income_by_security, total: Portfolio::Income.new(returns).total)
    end

    def lay_flat_balances(cash_by_date:, balance: 1_000)
      running = BigDecimal(balance)

      (@mar - 1..@last_day).each do |date|
        flow = BigDecimal(cash_by_date.fetch(date, 0).to_s)
        lay_balance account: @account, date: date, opening: running, closing: running + flow, cash_flow: flow
        running += flow
      end
    end
end
