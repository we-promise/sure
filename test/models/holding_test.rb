require "test_helper"
require "ostruct"
require "bigdecimal"

class HoldingTest < ActiveSupport::TestCase
  include EntriesTestHelper, SecuritiesTestHelper

  setup do
    @account = families(:empty).accounts.create!(name: "Test Brokerage", balance: 20000, cash_balance: 0, currency: "USD", accountable: Investment.new)

    # Current day holding instances
    @amzn, @nvda = load_holdings
  end

  test "calculates portfolio weight" do
    expected_amzn_weight = 3240.0 / @account.balance * 100
    expected_nvda_weight = 3720.0 / @account.balance * 100

    assert_in_delta expected_amzn_weight, @amzn.weight, 0.001
    assert_in_delta expected_nvda_weight, @nvda.weight, 0.001
  end

  test "calculates portfolio weight after converting foreign-currency holdings" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.5)

    foreign_security = Security.create!(ticker: "ASML", name: "ASML")
    foreign_holding = @account.holdings.create!(
      security: foreign_security,
      date: Date.current,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "EUR"
    )

    assert_in_delta 0.75, foreign_holding.weight, 0.001
  end

  test "calculates average cost basis" do
    create_trade(@amzn.security, account: @account, qty: 10, price: 212.00, date: 1.day.ago.to_date)
    create_trade(@amzn.security, account: @account, qty: 15, price: 216.00, date: Date.current)

    create_trade(@nvda.security, account: @account, qty: 5, price: 128.00, date: 1.day.ago.to_date)
    create_trade(@nvda.security, account: @account, qty: 30, price: 124.00, date: Date.current)

    # expected weighted averages (quantity-weighted)
    amzn_total = BigDecimal("10") * BigDecimal("212.00") + BigDecimal("15") * BigDecimal("216.00")
    amzn_qty   = BigDecimal("10") + BigDecimal("15")
    expected_amzn = amzn_total / amzn_qty

    nvda_total = BigDecimal("5") * BigDecimal("128.00") + BigDecimal("30") * BigDecimal("124.00")
    nvda_qty   = BigDecimal("5") + BigDecimal("30")
    expected_nvda = nvda_total / nvda_qty

    # At the four places `cost_basis` is stored at, as the calculators store it
    assert_equal Money.new(expected_amzn.round(4)), @amzn.avg_cost
    assert_equal Money.new(expected_nvda.round(4)), @nvda.avg_cost
  end

  test "calculates average cost basis from another currency" do
    [ 1.day.ago.to_date, Date.current ].each do |date|
      ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: date, rate: 1)
    end

    create_trade(@amzn.security, account: @account, qty: 10, price: 212.00, date: 1.day.ago.to_date, currency: "CAD")
    create_trade(@amzn.security, account: @account, qty: 15, price: 216.00, date: Date.current, currency: "CAD")

    create_trade(@nvda.security, account: @account, qty: 5, price: 128.00, date: 1.day.ago.to_date, currency: "CAD")
    create_trade(@nvda.security, account: @account, qty: 30, price: 124.00, date: Date.current, currency: "CAD")

    # compute expected: sum(price * qty * rate) / sum(qty)
    amzn_total_usd = BigDecimal("10") * BigDecimal("212.00") * BigDecimal("1") +
                     BigDecimal("15") * BigDecimal("216.00") * BigDecimal("1")
    amzn_qty = BigDecimal("10") + BigDecimal("15")
    expected_amzn_usd = amzn_total_usd / amzn_qty

    nvda_total_usd = BigDecimal("5") * BigDecimal("128.00") * BigDecimal("1") +
                     BigDecimal("30") * BigDecimal("124.00") * BigDecimal("1")
    nvda_qty = BigDecimal("5") + BigDecimal("30")
    expected_nvda_usd = nvda_total_usd / nvda_qty

    ExchangeRate.stubs(:find_or_fetch_rate).returns(OpenStruct.new(rate: 1))
    assert_equal Money.new(expected_amzn_usd.round(4), "CAD").exchange_to("USD"), @amzn.avg_cost
    assert_equal Money.new(expected_nvda_usd.round(4), "CAD").exchange_to("USD"), @nvda.avg_cost
  end

  test "the average cost includes what the purchases cost in fees" do
    create_trade(@amzn.security, account: @account, qty: 10, price: 212.00, fee: 10, date: 1.day.ago.to_date)
    create_trade(@amzn.security, account: @account, qty: 15, price: 216.00, fee: 5, date: Date.current)

    # (10 * 212 + 10 + 15 * 216 + 5) / 25 = 5,375 / 25
    assert_equal Money.new(BigDecimal("215")), @amzn.avg_cost
  end

  # The fallback's COALESCE(rate, 1) counted a foreign purchase at 1:1 when its
  # day had no rate, stating a cost that looks measured and is not.
  test "a foreign purchase with no rate for its day makes the average cost unknown" do
    create_trade(@amzn.security, account: @account, qty: 10, price: 212.00, date: 1.day.ago.to_date, currency: "CAD")

    assert_nil @amzn.avg_cost
  end

  test "a foreign purchase whose stored rate cannot convert makes the average cost unknown" do
    ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: 1.day.ago.to_date, rate: 0)
    create_trade(@amzn.security, account: @account, qty: 10, price: 212.00, date: 1.day.ago.to_date, currency: "CAD")

    assert_nil @amzn.avg_cost
  end

  test "the fallback converts a purchase at the rate it carries when the table has none" do
    entry = create_trade(@amzn.security, account: @account, qty: 10, price: 212.00, date: 1.day.ago.to_date, currency: "CAD")
    entry.entryable.update!(exchange_rate: 1.25)

    # 10 * 212 CAD at the trade's own 1.25 = 2,650 USD for 10 units
    assert_equal Money.new(BigDecimal("265")), @amzn.avg_cost
  end

  # Trade#exchange_rate= stores a number, but a rate written to `extra` directly
  # stays a string, and Trade and Money#exchange_to both accept it.
  test "the fallback converts a purchase at a rate it carries as a string" do
    entry = create_trade(@amzn.security, account: @account, qty: 10, price: 212.00, date: 1.day.ago.to_date, currency: "CAD")
    entry.entryable.update_column(:extra, { "exchange_rate" => "1.25" })

    assert entry.entryable.reload.valid?
    assert_equal Money.new(BigDecimal("265")), @amzn.avg_cost
  end

  test "the fallback ignores a rate string that is not a plain decimal" do
    entry = create_trade(@amzn.security, account: @account, qty: 10, price: 212.00, date: 1.day.ago.to_date, currency: "CAD")

    [ "n/a", "1e999999" ].each do |rate|
      entry.entryable.update_column(:extra, { "exchange_rate" => rate })

      assert_nil @amzn.avg_cost, rate
    end
  end

  # The missing-rate check rides on the totals query instead of adding a round
  # trip to a path that exists to avoid N+1 queries.
  test "the fallback reads the trades and the splits in one query each" do
    create_trade(@amzn.security, account: @account, qty: 10, price: 212.00, date: 1.day.ago.to_date)
    @amzn.account

    queries = capture_sql_queries { @amzn.avg_cost }

    assert_equal 1, queries.count { |sql| sql.include?('FROM "trades"') }
    assert_equal 1, queries.count { |sql| sql.include?('FROM "security_splits"') }
  end

  # The fallback answers for a holding with no stored basis, so it has to give
  # the figure the holding calculators would store (#3566): the same tracker,
  # relieving sells, splitting, and releasing a transfer once the position closes.
  test "the fallback relieves a full sell, so a rebuy starts a clean basis" do
    create_trade(@amzn.security, account: @account, qty: 10, price: 100, date: 10.days.ago.to_date)
    create_trade(@amzn.security, account: @account, qty: -10, price: 150, date: 5.days.ago.to_date)
    create_trade(@amzn.security, account: @account, qty: 10, price: 200, date: 1.day.ago.to_date)

    assert_equal Money.new(BigDecimal("200")), @amzn.avg_cost
  end

  test "the fallback relieves a partial sell at the running average" do
    create_trade(@amzn.security, account: @account, qty: 10, price: 100, date: 10.days.ago.to_date)
    create_trade(@amzn.security, account: @account, qty: -5, price: 150, date: 5.days.ago.to_date)
    create_trade(@amzn.security, account: @account, qty: 5, price: 200, date: 1.day.ago.to_date)

    # 5 left at 100, plus 5 at 200: 1,500 for 10 units
    assert_equal Money.new(BigDecimal("150")), @amzn.avg_cost
  end

  test "a transfer in stops making the fallback unknown once the position is closed" do
    transfer_in = create_trade(@amzn.security, account: @account, qty: 10, price: 100, date: 10.days.ago.to_date)
    transfer_in.entryable.update!(investment_activity_label: "Transfer")
    create_trade(@amzn.security, account: @account, qty: -10, price: 150, date: 5.days.ago.to_date)

    create_trade(@amzn.security, account: @account, qty: 10, price: 200, date: 1.day.ago.to_date)

    assert_equal Money.new(BigDecimal("200")), @amzn.avg_cost
  end

  test "the fallback stays unknown while transferred-in units are held" do
    transfer_in = create_trade(@amzn.security, account: @account, qty: 10, price: 100, date: 10.days.ago.to_date)
    transfer_in.entryable.update!(investment_activity_label: "Transfer")
    create_trade(@amzn.security, account: @account, qty: -5, price: 150, date: 5.days.ago.to_date)
    create_trade(@amzn.security, account: @account, qty: 10, price: 200, date: 1.day.ago.to_date)

    assert_nil @amzn.avg_cost
  end

  test "an outbound transfer is relieved like a sell in the fallback" do
    create_trade(@amzn.security, account: @account, qty: 10, price: 100, date: 10.days.ago.to_date)
    transfer_out = create_trade(@amzn.security, account: @account, qty: -10, price: 100, date: 5.days.ago.to_date)
    transfer_out.entryable.update!(investment_activity_label: "Transfer")
    create_trade(@amzn.security, account: @account, qty: 10, price: 200, date: 1.day.ago.to_date)

    assert_equal Money.new(BigDecimal("200")), @amzn.avg_cost
  end

  test "the fallback applies a stock split at the open of its ex-date" do
    create_trade(@amzn.security, account: @account, qty: 10, price: 100, date: 10.days.ago.to_date)
    @amzn.security.splits.create!(ex_date: 5.days.ago.to_date, numerator: 2, denominator: 1, source: "manual")
    create_trade(@amzn.security, account: @account, qty: 10, price: 60, date: 5.days.ago.to_date)

    # 1,000 for 20 post-split units, plus 600 for 10: 1,600 for 30, at the
    # four places `cost_basis` is stored at
    assert_equal Money.new(BigDecimal("53.3333")), @amzn.avg_cost
  end

  test "a buy with no rate stops making the fallback unknown once the position is closed" do
    create_trade(@amzn.security, account: @account, qty: 10, price: 100, date: 10.days.ago.to_date, currency: "CAD")
    create_trade(@amzn.security, account: @account, qty: -10, price: 150, date: 5.days.ago.to_date)
    create_trade(@amzn.security, account: @account, qty: 10, price: 200, date: 1.day.ago.to_date)

    assert_equal Money.new(BigDecimal("200")), @amzn.avg_cost
  end

  test "the fallback agrees with the forward calculator" do
    account = families(:empty).accounts.create!(name: "Parity Brokerage", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new)
    security = create_security("PRTY", prices: (0..12).map { |days| { date: days.days.ago.to_date, price: 120 } })

    create_trade(security, account: account, qty: 10, price: 100, fee: 10, date: 12.days.ago.to_date)
    create_trade(security, account: account, qty: -4, price: 130, date: 10.days.ago.to_date)
    transfer_in = create_trade(security, account: account, qty: 3, price: 90, date: 9.days.ago.to_date)
    transfer_in.entryable.update!(investment_activity_label: "Transfer")
    create_trade(security, account: account, qty: -9, price: 140, date: 8.days.ago.to_date)
    create_trade(security, account: account, qty: 8, price: 110, fee: 4, date: 7.days.ago.to_date)
    security.splits.create!(ex_date: 6.days.ago.to_date, numerator: 3, denominator: 2, source: "manual")
    transfer_out = create_trade(security, account: account, qty: -3, price: 75, date: 5.days.ago.to_date)
    transfer_out.entryable.update!(investment_activity_label: "Transfer")
    create_trade(security, account: account, qty: 6, price: 80, date: 3.days.ago.to_date)

    Holding::Materializer.new(account, strategy: :forward).materialize_holdings
    holdings = account.holdings.where(security: security).where("date >= ?", 7.days.ago.to_date).order(:date).to_a

    assert holdings.all? { |holding| holding.cost_basis.present? }, "every compared day needs a calculated basis"
    holdings.each do |holding|
      assert_equal holding.cost_basis, holding.send(:calculate_avg_cost)&.amount, holding.date.to_s
    end
  end

  # The two paths convert differently: the fallback joins the rate stored for
  # the trade's exact date, the calculators go through Money#exchange_to. With
  # a rate on every trade date those must give the same figure.
  test "the fallback agrees with the forward calculator for trades in another currency" do
    account = families(:empty).accounts.create!(name: "FX Parity Brokerage", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new)
    security = create_security("FXPT", prices: (0..12).map { |days| { date: days.days.ago.to_date, price: 120 } })

    { 12 => 0.70, 10 => 0.72, 8 => 0.75, 5 => 0.74, 3 => 0.73, 2 => 0.71 }.each do |days, rate|
      ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: days.days.ago.to_date, rate: rate)
    end

    create_trade(security, account: account, qty: 10, price: 100, fee: 10, currency: "CAD", date: 12.days.ago.to_date)
    create_trade(security, account: account, qty: -4, price: 130, currency: "CAD", date: 10.days.ago.to_date)
    create_trade(security, account: account, qty: 6, price: 110, fee: 4, currency: "CAD", date: 8.days.ago.to_date)
    security.splits.create!(ex_date: 6.days.ago.to_date, numerator: 3, denominator: 2, source: "manual")
    # A rate the trade carries itself comes before the table's 0.74
    own_rate = create_trade(security, account: account, qty: 4, price: 90, currency: "CAD", date: 5.days.ago.to_date)
    own_rate.entryable.update!(exchange_rate: 0.8)
    create_trade(security, account: account, qty: 3, price: 85, date: 4.days.ago.to_date)
    create_trade(security, account: account, qty: -10, price: 140, currency: "CAD", date: 3.days.ago.to_date)
    create_trade(security, account: account, qty: 5, price: 100, fee: 5, currency: "CAD", date: 2.days.ago.to_date)

    Holding::Materializer.new(account, strategy: :forward).materialize_holdings
    holdings = account.holdings.where(security: security).order(:date).to_a

    assert_equal 13, holdings.size
    # (100 + 10 / 10) CAD at 0.70: the first day's basis is converted in USD
    assert_equal BigDecimal("70.7"), holdings.first.cost_basis
    assert holdings.all? { |holding| holding.cost_basis.present? }, "every compared day needs a calculated basis"
    holdings.each do |holding|
      assert_equal holding.cost_basis, holding.send(:calculate_avg_cost)&.amount, holding.date.to_s
    end
  end

  # Known divergence, out of scope here (we-promise/sure#2012): with no rate
  # stored for a foreign trade's own date, Money#exchange_to falls back to the
  # nearest earlier rate, so the calculator stores a basis, while the fallback's
  # exact-date join finds no rate and reports the cost as unknown. This pins
  # both answers so a change to either path shows up here.
  test "the fallback reports unknown where the calculator uses an earlier rate (#2012)" do
    account = families(:empty).accounts.create!(name: "FX Gap Brokerage", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new)
    security = create_security("FXGP", prices: (0..5).map { |days| { date: days.days.ago.to_date, price: 120 } })

    ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: 5.days.ago.to_date, rate: 0.70)
    create_trade(security, account: account, qty: 10, price: 100, currency: "CAD", date: 3.days.ago.to_date)

    Holding::Materializer.new(account, strategy: :forward).materialize_holdings
    holding = account.holdings.find_by!(security: security, date: 3.days.ago.to_date)

    assert_equal BigDecimal("70"), holding.cost_basis
    assert_nil holding.send(:calculate_avg_cost)
  end

  test "calculates total return trend" do
    @amzn.stubs(:avg_cost).returns(Money.new(214.00))
    @nvda.stubs(:avg_cost).returns(Money.new(126.00))

    # Gained $30, or 0.93%
    assert_equal Money.new(30), @amzn.trend.value
    assert_in_delta 0.9, @amzn.trend.percent, 0.001

    # Lost $60, or -1.59%
    assert_equal Money.new(-60), @nvda.trend.value
    assert_in_delta -1.6, @nvda.trend.percent, 0.001
  end

  test "avg_cost returns nil when no trades exist and no stored cost_basis" do
    # Holdings created without trades should return nil for avg_cost
    # This prevents displaying fake $0 gain/loss based on current market price
    assert_nil @amzn.avg_cost
    assert_nil @nvda.avg_cost
  end

  test "avg_cost uses stored cost_basis when available" do
    # Simulate provider-supplied cost_basis (e.g., from SimpleFIN)
    @amzn.update!(cost_basis: 200.00)

    assert_equal Money.new(200.00, "USD"), @amzn.avg_cost
  end

  test "avg_cost treats zero cost_basis as unknown when not locked" do
    # Some providers return 0 when they don't have cost basis data
    # This should be treated as "unknown" (return nil), not as $0 cost
    @amzn.update!(cost_basis: 0, cost_basis_locked: false)

    assert_nil @amzn.avg_cost
  end

  test "avg_cost returns zero cost_basis when locked (e.g., airdrops)" do
    # User-set $0 cost basis is valid for airdrops and should be honored
    @amzn.update!(cost_basis: 0, cost_basis_source: "manual", cost_basis_locked: true)

    assert_equal Money.new(0, "USD"), @amzn.avg_cost
  end

  test "trend returns nil when cost basis is unknown" do
    # Without cost basis, we can't calculate unrealized gain/loss
    assert_nil @amzn.trend
    assert_nil @nvda.trend
  end

  test "trend works when avg_cost is available" do
    @amzn.update!(cost_basis: 214.00)

    # Current price is 216, cost basis is 214
    # Qty is 15, so gain = 15 * (216 - 214) = $30
    assert_not_nil @amzn.trend
    assert_equal Money.new(30), @amzn.trend.value
  end

  # Cost basis source tracking tests

  test "cost_basis_replaceable_by? returns false when locked" do
    @amzn.update!(cost_basis: 200, cost_basis_source: "manual", cost_basis_locked: true)

    assert_not @amzn.cost_basis_replaceable_by?("calculated")
    assert_not @amzn.cost_basis_replaceable_by?("provider")
    assert_not @amzn.cost_basis_replaceable_by?("manual")
  end

  test "cost_basis_replaceable_by? respects priority hierarchy and allows refreshes" do
    # Provider data can be replaced by higher-priority sources (calculated/manual)
    # and can be refreshed by provider again.
    @amzn.update!(cost_basis: 200, cost_basis_source: "provider", cost_basis_locked: false)
    assert @amzn.cost_basis_replaceable_by?("calculated")
    assert @amzn.cost_basis_replaceable_by?("manual")
    assert @amzn.cost_basis_replaceable_by?("provider")

    # Calculated data can be replaced by manual and can be refreshed by calculated again.
    @amzn.update!(cost_basis: 200, cost_basis_source: "calculated", cost_basis_locked: false)
    assert @amzn.cost_basis_replaceable_by?("manual")
    assert @amzn.cost_basis_replaceable_by?("calculated")
    assert_not @amzn.cost_basis_replaceable_by?("provider")

    # Manual data when LOCKED cannot be replaced by anything
    @amzn.update!(cost_basis: 200, cost_basis_source: "manual", cost_basis_locked: true)
    assert_not @amzn.cost_basis_replaceable_by?("manual")
    assert_not @amzn.cost_basis_replaceable_by?("calculated")
    assert_not @amzn.cost_basis_replaceable_by?("provider")

    # Manual data when UNLOCKED can be replaced by calculated (enables recalculation)
    @amzn.update!(cost_basis: 200, cost_basis_source: "manual", cost_basis_locked: false)
    assert_not @amzn.cost_basis_replaceable_by?("manual")
    assert @amzn.cost_basis_replaceable_by?("calculated")
    assert_not @amzn.cost_basis_replaceable_by?("provider")
  end

  test "set_manual_cost_basis! sets value and locks" do
    @amzn.set_manual_cost_basis!(BigDecimal("175.50"))

    assert_equal BigDecimal("175.50"), @amzn.cost_basis
    assert_equal "manual", @amzn.cost_basis_source
    assert @amzn.cost_basis_locked?
  end

  test "unlock_cost_basis! allows future updates" do
    @amzn.set_manual_cost_basis!(BigDecimal("175.50"))
    @amzn.unlock_cost_basis!

    assert_not @amzn.cost_basis_locked?
    # Source remains manual but since unlocked, calculated could now overwrite
    assert @amzn.cost_basis_replaceable_by?("calculated")
  end

  test "cost_basis_source_label returns correct translation" do
    @amzn.update!(cost_basis_source: "manual")
    assert_equal I18n.t("holdings.cost_basis_sources.manual"), @amzn.cost_basis_source_label

    @amzn.update!(cost_basis_source: "calculated")
    assert_equal I18n.t("holdings.cost_basis_sources.calculated"), @amzn.cost_basis_source_label

    @amzn.update!(cost_basis_source: "provider")
    assert_equal I18n.t("holdings.cost_basis_sources.provider"), @amzn.cost_basis_source_label

    @amzn.update!(cost_basis_source: nil)
    assert_nil @amzn.cost_basis_source_label
  end

  test "cost_basis_known? returns true only when source and positive value exist" do
    @amzn.update!(cost_basis: nil, cost_basis_source: nil)
    assert_not @amzn.cost_basis_known?

    @amzn.update!(cost_basis: 200, cost_basis_source: nil)
    assert_not @amzn.cost_basis_known?

    @amzn.update!(cost_basis: nil, cost_basis_source: "provider")
    assert_not @amzn.cost_basis_known?

    @amzn.update!(cost_basis: 0, cost_basis_source: "provider")
    assert_not @amzn.cost_basis_known?

    @amzn.update!(cost_basis: 200, cost_basis_source: "provider")
    assert @amzn.cost_basis_known?
  end

  # Precision and edge case tests

  test "cost_basis precision is maintained with fractional shares" do
    @amzn.update!(qty: BigDecimal("0.123456"))
    @amzn.set_manual_cost_basis!(BigDecimal("100.123456"))
    @amzn.reload

    assert_in_delta 100.123456, @amzn.cost_basis.to_f, 0.0001
  end

  test "set_manual_cost_basis! with zero qty does not raise but saves the value" do
    @amzn.update!(qty: 0)
    @amzn.set_manual_cost_basis!(BigDecimal("100"))

    # Value is stored but effectively meaningless with zero qty
    assert_equal BigDecimal("100"), @amzn.cost_basis
    assert @amzn.cost_basis_locked?
  end

  test "cost_basis_locked prevents all sources from overwriting" do
    @amzn.set_manual_cost_basis!(BigDecimal("100"))
    assert @amzn.cost_basis_locked?

    # Verify all sources are blocked when locked
    assert_not @amzn.cost_basis_replaceable_by?("provider")
    assert_not @amzn.cost_basis_replaceable_by?("calculated")
    assert_not @amzn.cost_basis_replaceable_by?("manual")

    # Value should remain unchanged
    assert_equal BigDecimal("100"), @amzn.cost_basis
  end

  test "unlocked manual allows only calculated to replace" do
    @amzn.set_manual_cost_basis!(BigDecimal("100"))
    @amzn.unlock_cost_basis!

    assert_not @amzn.cost_basis_locked?
    assert @amzn.cost_basis_replaceable_by?("calculated")
    assert_not @amzn.cost_basis_replaceable_by?("provider")
    assert_not @amzn.cost_basis_replaceable_by?("manual")
  end

  # Security remapping tests

  test "security_replaceable_by_provider? returns false when locked" do
    @amzn.update!(security_locked: true)
    assert_not @amzn.security_replaceable_by_provider?
  end

  test "security_replaceable_by_provider? returns true when not locked" do
    @amzn.update!(security_locked: false)
    assert @amzn.security_replaceable_by_provider?
  end

  test "security_remapped? returns true when provider_security differs from security" do
    other_security = create_security("GOOG", prices: [ { date: Date.current, price: 100.00 } ])
    @amzn.update!(provider_security: other_security)
    assert @amzn.security_remapped?
  end

  test "security_remapped? returns false when provider_security is nil" do
    assert_nil @amzn.provider_security_id
    assert_not @amzn.security_remapped?
  end

  test "security_remapped? returns false when provider_security equals security" do
    @amzn.update!(provider_security: @amzn.security)
    assert_not @amzn.security_remapped?
  end

  test "remap_security! changes holding security and locks it" do
    old_security = @amzn.security
    new_security = create_security("GOOG", prices: [ { date: Date.current, price: 100.00 } ])

    @amzn.remap_security!(new_security)

    assert_equal new_security, @amzn.security
    assert @amzn.security_locked?
    assert_equal old_security, @amzn.provider_security
  end

  test "remap_security! updates all holdings for the same security" do
    old_security = @amzn.security
    new_security = create_security("GOOG", prices: [ { date: Date.current, price: 100.00 } ])

    # There are 2 AMZN holdings (from load_holdings) - yesterday and today
    amzn_holdings_count = @account.holdings.where(security: old_security).count
    assert_equal 2, amzn_holdings_count

    @amzn.remap_security!(new_security)

    # All holdings should now be for the new security
    assert_equal 0, @account.holdings.where(security: old_security).count
    assert_equal 2, @account.holdings.where(security: new_security).count

    # All should be locked with provider_security set
    @account.holdings.where(security: new_security).each do |h|
      assert h.security_locked?
      assert_equal old_security, h.provider_security
    end
  end

  test "remap_security! moves trades to new security" do
    old_security = @amzn.security
    new_security = create_security("GOOG", prices: [ { date: Date.current, price: 100.00 } ])

    # Create a trade for the old security
    create_trade(old_security, account: @account, qty: 5, price: 100.00, date: Date.current)
    assert_equal 1, @account.trades.where(security: old_security).count

    @amzn.remap_security!(new_security)

    # Trade should have moved to the new security
    assert_equal 0, @account.trades.where(security: old_security).count
    assert_equal 1, @account.trades.where(security: new_security).count
  end

  test "remap_security! does nothing when security is same" do
    current_security = @amzn.security

    @amzn.remap_security!(current_security)

    assert_equal current_security, @amzn.security
    assert_not @amzn.security_locked?
    assert_nil @amzn.provider_security_id
  end

  test "remap_security! merges holdings on collision by combining qty and amount" do
    new_security = create_security("GOOG", prices: [ { date: Date.current, price: 100.00 } ])

    # Create an existing holding for the new security on the same date
    existing_goog = @account.holdings.create!(
      date: @amzn.date,
      security: new_security,
      qty: 5,
      price: 100,
      amount: 500,
      currency: "USD"
    )

    amzn_security = @amzn.security
    amzn_qty = @amzn.qty
    amzn_amount = @amzn.amount
    initial_count = @account.holdings.count

    # Remap should merge by combining qty and amount
    @amzn.remap_security!(new_security)

    # The AMZN holding on collision date should be deleted, merged into GOOG
    assert_equal initial_count - 1, @account.holdings.count

    # The existing GOOG holding should have merged values
    existing_goog.reload
    assert_equal 5 + amzn_qty, existing_goog.qty
    assert_equal 500 + amzn_amount, existing_goog.amount

    # Merged holding should be locked to prevent provider overwrites
    assert existing_goog.security_locked, "Merged holding should be locked"

    # No holdings should remain for the old AMZN security
    assert_equal 0, @account.holdings.where(security: amzn_security).count
  end

  test "reset_security_to_provider! restores original security" do
    old_security = @amzn.security
    new_security = create_security("GOOG", prices: [ { date: Date.current, price: 100.00 } ])

    @amzn.remap_security!(new_security)
    assert_equal new_security, @amzn.security
    assert @amzn.security_locked?

    @amzn.reset_security_to_provider!

    assert_equal old_security, @amzn.security
    assert_not @amzn.security_locked?
    assert_nil @amzn.provider_security_id
  end

  test "reset_security_to_provider! moves trades back" do
    old_security = @amzn.security
    new_security = create_security("GOOG", prices: [ { date: Date.current, price: 100.00 } ])

    create_trade(old_security, account: @account, qty: 5, price: 100.00, date: Date.current)

    @amzn.remap_security!(new_security)
    assert_equal 1, @account.trades.where(security: new_security).count

    @amzn.reset_security_to_provider!
    assert_equal 0, @account.trades.where(security: new_security).count
    assert_equal 1, @account.trades.where(security: old_security).count
  end

  test "reset_security_to_provider! does nothing if not remapped" do
    old_security = @amzn.security
    @amzn.reset_security_to_provider!

    assert_equal old_security, @amzn.security
    assert_nil @amzn.provider_security_id
  end

  private

    def load_holdings
      security1 = create_security("AMZN", prices: [
        { date: 1.day.ago.to_date, price: 212.00 },
        { date: Date.current, price: 216.00 }
      ])

      security2 = create_security("NVDA", prices: [
        { date: 1.day.ago.to_date, price: 128.00 },
        { date: Date.current, price: 124.00 }
      ])

      create_holding(security1, 1.day.ago.to_date, 10)
      amzn = create_holding(security1, Date.current, 15)

      create_holding(security2, 1.day.ago.to_date, 5)
      nvda = create_holding(security2, Date.current, 30)

      [ amzn, nvda ]
    end

    def create_holding(security, date, qty)
      price = Security::Price.find_by(date: date, security: security).price

      @account.holdings.create! \
        date: date,
        security: security,
        qty: qty,
        price: price,
        amount: qty * price,
        currency: "USD"
    end

    # A coin bought elsewhere at one price and moved in at another was never
    # bought here, so counting the day it arrived as its cost reports a gain of
    # zero on a position that may have doubled.
    test "an internal movement does not set the cost basis" do
      holding = holdings(:one)

      Trade::INTERNAL_MOVEMENT_LABELS.each do |label|
        holding.account.trades.each { |trade| trade.update!(investment_activity_label: label) }

        assert_nil holding.avg_cost,
          "a position moved by #{label} has no cost basis this app can know"
      end
    end

    # `!=` is NULL for an unlabelled row, so a naive exclusion drops the ordinary
    # purchases that carry no label — which is most of them.
    test "an unlabelled purchase still sets it" do
      holding = holdings(:one)
      holding.account.trades.each { |t| t.update!(investment_activity_label: nil) }

      assert_not_nil holding.avg_cost
    end

    # Averaging the purchases alone and applying that to every unit is the same
    # fabrication in a quieter form.
    test "a position mixing a purchase and a transfer has no knowable cost" do
      holding = holdings(:one)
      holding.account.trades.each { |t| t.update!(investment_activity_label: "Buy") }

      holding.account.entries.create!(
        date: holding.date - 1,
        name: "Received 1 unit",
        amount: -100,
        currency: holding.currency,
        entryable: Trade.new(
          security: holding.security,
          qty: 1,
          price: 100,
          currency: holding.currency,
          investment_activity_label: Trade::TRANSFER_LABEL
        )
      )

      assert_nil holding.avg_cost
    end

    # A figure the user typed is theirs, not ours to discard: they are saying
    # what the position cost them, which is exactly what the app cannot work
    # out on its own for a transfer.
    test "a cost basis the user set survives a transfer" do
      holding = holdings(:one)
      holding.account.trades.each { |t| t.update!(investment_activity_label: Trade::TRANSFER_LABEL) }
      holding.update_columns(cost_basis: 100, cost_basis_source: "manual")

      assert_equal 100, holding.reload.avg_cost.amount.to_d
    end

    test "a purchase still sets it" do
        holding = holdings(:one)
        holding.account.trades.each { |t| t.update!(investment_activity_label: "Buy") }

        assert_not_nil holding.avg_cost
      end
end
