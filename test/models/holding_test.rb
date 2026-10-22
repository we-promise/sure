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

    assert_equal Money.new(expected_amzn), @amzn.avg_cost
    assert_equal Money.new(expected_nvda), @nvda.avg_cost
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
    assert_equal Money.new(expected_amzn_usd, "CAD").exchange_to("USD"), @amzn.avg_cost
    assert_equal Money.new(expected_nvda_usd, "CAD").exchange_to("USD"), @nvda.avg_cost
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

  # `exchange_rates` no longer stores a 0, but a rate written to the trade's
  # `extra` directly still can, and the cost must not trust it either.
  test "a foreign purchase whose stored rate cannot convert makes the average cost unknown" do
    entry = create_trade(@amzn.security, account: @account, qty: 10, price: 212.00, date: 1.day.ago.to_date, currency: "CAD")
    entry.entryable.update_column(:extra, (entry.entryable.extra || {}).merge("exchange_rate" => 0))

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
  test "the fallback reads the trades in two queries" do
    create_trade(@amzn.security, account: @account, qty: 10, price: 212.00, date: 1.day.ago.to_date)
    @amzn.account

    queries = capture_sql_queries { @amzn.avg_cost }

    assert_equal 2, queries.count { |sql| sql.include?('FROM "trades"') }
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

  # Holdings are derived rows the materializer writes with upsert_all, which
  # skips validations, so a full in-kind transfer out can leave a row with a
  # negative qty and amount. Remapping or resetting such a row must not be
  # vetoed by the >= 0 validations meant for user edits.

  test "remap_security! moves a negative-amount holding onto another security (no collision)" do
    record_a = create_security("AAAX", prices: [ { date: 1.day.ago.to_date, price: 50.00 } ])
    record_b = create_security("BBX", prices: [ { date: Date.current, price: 144.90 } ])

    # record_a holds a row on a different date, so the move does not collide.
    create_trade(record_a, account: @account, qty: 22, price: 50.00, date: 1.day.ago.to_date)
    @account.holdings.create!(security: record_a, date: 1.day.ago.to_date, qty: 22, price: 50.00, amount: 1100.0, currency: "USD")

    neg = @account.holdings.create!(security: record_b, date: Date.current, qty: 22, price: 144.905, amount: 3187.91, currency: "USD")
    neg.update_columns(qty: -22, amount: BigDecimal("-3187.80"))

    neg.reload.remap_security!(record_a)

    assert_equal 0, @account.holdings.where(security: record_b).count
    row = @account.holdings.find_by(security: record_a, date: Date.current)
    refute_nil row
    assert_equal BigDecimal("-22"), row.qty
    assert_equal BigDecimal("-3187.80"), row.amount
    assert row.security_locked?
    assert_equal record_b.id, row.provider_security_id
  end

  test "remap_security! merges a holding into a negative target without raising (collision)" do
    new_security = create_security("GOOGNEG", prices: [ { date: Date.current, price: 100.0 } ])

    target = @account.holdings.create!(date: Date.current, security: new_security, qty: 0, price: 100.0, amount: 0.0, currency: "USD")
    target.update_columns(qty: -22, amount: -4000.0)

    amzn_security = @amzn.security
    initial_count = @account.holdings.count

    @amzn.remap_security!(new_security)

    assert_equal initial_count - 1, @account.holdings.count
    assert_equal 0, @account.holdings.where(security: amzn_security).count
    target.reload
    # -22 + the moved row's 15, and -4000 + its 3240: both still negative.
    assert_equal BigDecimal("-7"), target.qty
    assert_equal BigDecimal("-760"), target.amount
    # The calculators write amount = qty x price with a positive price, so a
    # negative row's price is still amount / qty.
    assert_in_delta BigDecimal("108.5714"), target.price, BigDecimal("0.0001")
    assert target.security_locked?
  end

  test "remap_security! gives a merged row that nets to zero a zero price" do
    new_security = create_security("GOOGZERO", prices: [ { date: Date.current, price: 100.0 } ])
    target = @account.holdings.create!(date: Date.current, security: new_security, qty: 0, price: 100.0, amount: 0.0, currency: "USD")
    target.update_columns(qty: -@amzn.qty, amount: -@amzn.amount)

    @amzn.remap_security!(new_security)

    target.reload
    assert_equal [ BigDecimal("0"), BigDecimal("0"), BigDecimal("0") ], [ target.qty, target.amount, target.price ]
  end

  # Two rows priced differently can sum to a qty and an amount of opposite
  # signs, where amount / qty would be a negative price. The materializer
  # prices the row at the target security's own price for that date, so the
  # merge keeps the target's price.
  test "remap_security! keeps the target's price when a merge nets to opposite signs" do
    new_security = create_security("GOOGOPP", prices: [ { date: Date.current, price: 136.3636 } ])
    target = @account.holdings.create!(date: Date.current, security: new_security, qty: 0, price: 136.3636, amount: 0.0, currency: "USD")
    target.update_columns(qty: -22, amount: -3000.0)

    @amzn.remap_security!(new_security)

    target.reload
    # -22 + the moved row's 15, and -3000 + its 3240.
    assert_equal BigDecimal("-7"), target.qty
    assert_equal BigDecimal("240"), target.amount
    assert_equal BigDecimal("136.3636"), target.price
  end

  test "remap_security! keeps the target's price when a merge nets to a positive qty and negative amount" do
    new_security = create_security("GOOGOPQ", prices: [ { date: Date.current, price: 4.5 } ])
    target = @account.holdings.create!(date: Date.current, security: new_security, qty: 22, price: 4.5, amount: 99.0, currency: "USD")
    @amzn.update_columns(qty: -15, amount: -3240.0)

    @amzn.remap_security!(new_security)

    target.reload
    assert_equal BigDecimal("7"), target.qty
    assert_equal BigDecimal("-3141"), target.amount
    assert_equal BigDecimal("4.5"), target.price
  end

  test "reset_security_to_provider! moves a negative-qty holding back without raising" do
    old_security = @amzn.security
    new_security = create_security("GOOGRST", prices: [ { date: Date.current, price: 100.0 } ])

    @amzn.remap_security!(new_security)
    assert_equal new_security.id, @amzn.security_id

    @amzn.update_columns(qty: -22, amount: BigDecimal("-3187.80"))

    @amzn.reset_security_to_provider!

    @amzn.reload
    assert_equal old_security.id, @amzn.security_id
    assert_not @amzn.security_locked?
    assert_nil @amzn.provider_security_id
  end

  # save!/update! set updated_at, and Holding::CurrentForInvestmentAccounts and
  # Security::Price::ImportWindows read it, so the remap and reset writes keep
  # setting it.
  test "remap_security! bumps updated_at on a moved holding" do
    new_security = create_security("GOOGTS", prices: [ { date: Date.current, price: 100.0 } ])
    @account.holdings.update_all(updated_at: 2.days.ago)
    before = @account.holdings.maximum(:updated_at)

    @amzn.remap_security!(new_security)

    moved = @account.holdings.where(security: new_security)
    assert_equal 2, moved.count
    moved.each { |h| assert_operator h.updated_at, :>, before }
  end

  test "remap_security! bumps updated_at on the row it merges into" do
    new_security = create_security("GOOGTM", prices: [ { date: Date.current, price: 100.0 } ])
    target = @account.holdings.create!(security: new_security, date: @amzn.date, qty: 1, price: 100.0, amount: 100.0, currency: @amzn.currency)
    @account.holdings.update_all(updated_at: 2.days.ago)
    before = target.reload.updated_at

    @amzn.remap_security!(new_security)

    assert_operator target.reload.updated_at, :>, before
  end

  test "reset_security_to_provider! bumps updated_at on the holdings it moves back" do
    old_security = @amzn.security
    new_security = create_security("GOOGTR", prices: [ { date: Date.current, price: 100.0 } ])
    @amzn.remap_security!(new_security)
    @account.holdings.update_all(updated_at: 2.days.ago)
    before = @account.holdings.maximum(:updated_at)

    @amzn.reset_security_to_provider!

    reset = @account.holdings.where(security: old_security)
    assert_equal 2, reset.count
    reset.each { |h| assert_operator h.updated_at, :>, before }
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
