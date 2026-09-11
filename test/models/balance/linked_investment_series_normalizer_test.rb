require "test_helper"

class Balance::LinkedInvestmentSeriesNormalizerTest < ActiveSupport::TestCase
  test "pending transactions do not establish supported balance history" do
    account = families(:empty).accounts.create!(
      name: "Linked Investment",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    pending_date = 5.days.ago.to_date
    posted_date = 2.days.ago.to_date

    account.entries.create!(
      date: pending_date,
      name: "Pending Transaction",
      amount: 100,
      currency: "USD",
      source: "plaid",
      entryable: Transaction.new(extra: { "plaid" => { "pending" => true } })
    )
    account.entries.create!(
      date: posted_date,
      name: "Posted Transaction",
      amount: 100,
      currency: "USD",
      source: "plaid",
      entryable: Transaction.new
    )

    start_date = Balance::LinkedInvestmentSeriesNormalizer
      .send(:common_supported_history_start_date, [ account.id ])

    assert_equal posted_date, start_date
  end

  test "common_supported_history_start_date includes opening anchor valuation date" do
    account = families(:empty).accounts.create!(
      name: "Linked Investment Anchor",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    anchor_date = 20.days.ago.to_date
    posted_date = 10.days.ago.to_date

    account.set_opening_anchor_balance(balance: 100, date: anchor_date)
    account.entries.create!(
      date: posted_date,
      name: "Posted Transaction",
      amount: 100,
      currency: "USD",
      source: "plaid",
      entryable: Transaction.new
    )

    start_date = Balance::LinkedInvestmentSeriesNormalizer
      .send(:common_supported_history_start_date, [ account.id ])

    assert_equal anchor_date, start_date
  end

  test "common_supported_history_start_date prefers trade date over later valuation" do
    account = families(:empty).accounts.create!(
      name: "Linked Investment Trade First",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    trade_date = 2.years.ago.to_date
    later_valuation_date = 6.months.ago.to_date

    account.entries.create!(
      date: trade_date,
      name: "Early Trade",
      amount: 50,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    account.entries.create!(
      date: later_valuation_date,
      name: "Reconciliation Valuation",
      amount: 500,
      currency: "USD",
      source: "snaptrade",
      entryable: Valuation.new(kind: "reconciliation")
    )

    start_date = Balance::LinkedInvestmentSeriesNormalizer
      .send(:common_supported_history_start_date, [ account.id ])

    assert_equal trade_date, start_date
  end

  test "normalizer leaves series untouched for unlinked accounts" do
    account = families(:empty).accounts.create!(
      name: "Unlinked Account",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    assert account.unlinked?

    raw_series = Series.new(
      start_date: 5.years.ago.to_date,
      end_date: Date.current,
      interval: "1 month",
      values: [
        Series::Value.new(date: 5.years.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(100, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalizer = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series)
    assert_same raw_series, normalizer.normalize
  end

  test "normalizer prepends opening anchor with non-zero opening balance when coarse sampling misses date" do
    account = families(:empty).accounts.create!(
      name: "Linked With Anchor Balance",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    opening_date = 8.days.ago.to_date
    account.set_opening_anchor_balance(balance: 500, date: opening_date)
    account.entries.create!(
      name: "Trade",
      date: opening_date,
      amount: 100,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    raw_series = Series.new(
      start_date: 10.days.ago.to_date,
      end_date: Date.current,
      interval: "1 week",
      values: [
        Series::Value.new(date: 10.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: 3.days.ago.to_date, date_formatted: "", value: Money.new(600, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(650, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalizer = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series)
    normalized = normalizer.normalize

    assert_equal opening_date, normalized.start_date
    assert_equal [ opening_date, 3.days.ago.to_date, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(500, "USD"), normalized.values.first.value
  end

  test "normalizer does not duplicate anchor point when coarse sample lands on exact opening date" do
    account = families(:empty).accounts.create!(
      name: "Linked Exact Date",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    opening_date = 7.days.ago.to_date
    account.set_opening_anchor_balance(balance: 0, date: opening_date)
    account.entries.create!(
      name: "Trade",
      date: opening_date,
      amount: 100,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    raw_series = Series.new(
      start_date: 14.days.ago.to_date,
      end_date: Date.current,
      interval: "1 week",
      values: [
        Series::Value.new(date: 14.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: opening_date, date_formatted: "", value: Money.new(100, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(110, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalizer = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series)
    normalized = normalizer.normalize

    assert_equal opening_date, normalized.start_date
    assert_equal [ opening_date, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(100, "USD"), normalized.values.first.value
  end

  test "normalizer returns series unmodified when linked account has no history" do
    account = families(:empty).accounts.create!(
      name: "Empty Linked Account",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    raw_series = Series.new(
      start_date: 30.days.ago.to_date,
      end_date: Date.current,
      interval: "1 day",
      values: [
        Series::Value.new(date: 30.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(0, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalizer = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series)
    assert_same raw_series, normalizer.normalize
  end

  test "normalizer does not prepend anchor when account inception predates series start_date" do
    account = families(:empty).accounts.create!(
      name: "Established Linked Account",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    two_years_ago = 2.years.ago.to_date
    account.set_opening_anchor_balance(balance: 0, date: two_years_ago)
    account.entries.create!(
      name: "Old Trade",
      date: two_years_ago,
      amount: 100,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    # 30-day series
    thirty_days_ago = 30.days.ago.to_date
    raw_series = Series.new(
      start_date: thirty_days_ago,
      end_date: Date.current,
      interval: "1 day",
      values: [
        Series::Value.new(date: thirty_days_ago, date_formatted: "", value: Money.new(500, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(550, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalizer = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series)
    normalized = normalizer.normalize

    assert_equal thirty_days_ago, normalized.start_date
    assert_equal [ thirty_days_ago, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(500, "USD"), normalized.values.first.value
  end

  test "normalizer synthesizes 0 gains for gains view even if opening anchor balance is positive" do
    account = families(:empty).accounts.create!(
      name: "Gains View Account",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    opening_date = 8.days.ago.to_date
    account.set_opening_anchor_balance(balance: 5000, date: opening_date)
    account.entries.create!(
      name: "Trade",
      date: opening_date,
      amount: 100,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    raw_series = Series.new(
      start_date: 10.days.ago.to_date,
      end_date: Date.current,
      interval: "1 week",
      values: [
        Series::Value.new(date: 10.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: 3.days.ago.to_date, date_formatted: "", value: Money.new(200, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(250, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalizer = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series, view: :gains)
    normalized = normalizer.normalize

    assert_equal opening_date, normalized.start_date
    assert_equal [ opening_date, 3.days.ago.to_date, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(0, "USD"), normalized.values.first.value
  end

  test "normalizer synthesizes 0 holdings for holdings_balance view even if opening anchor balance is positive" do
    account = families(:empty).accounts.create!(
      name: "Holdings View Account",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    opening_date = 8.days.ago.to_date
    account.set_opening_anchor_balance(balance: 5000, date: opening_date)
    account.entries.create!(
      name: "Trade",
      date: opening_date,
      amount: 100,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    raw_series = Series.new(
      start_date: 10.days.ago.to_date,
      end_date: Date.current,
      interval: "1 week",
      values: [
        Series::Value.new(date: 10.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: 3.days.ago.to_date, date_formatted: "", value: Money.new(4500, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(4800, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalizer = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series, view: :holdings_balance)
    normalized = normalizer.normalize

    assert_equal opening_date, normalized.start_date
    assert_equal [ opening_date, 3.days.ago.to_date, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(0, "USD"), normalized.values.first.value
  end
end
