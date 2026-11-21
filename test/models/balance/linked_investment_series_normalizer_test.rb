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

  test "common_supported_history_start_date ignores unlinked manual accounts in mixed portfolio" do
    linked_account = families(:empty).accounts.create!(
      name: "Linked Investment",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    manual_account = families(:empty).accounts.create!(
      name: "Manual Investment",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )

    linked_activity_date = 20.days.ago.to_date
    manual_anchor_date = 5.days.ago.to_date

    linked_account.entries.create!(
      date: linked_activity_date,
      name: "Trade",
      amount: 100,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )
    manual_account.set_opening_anchor_balance(balance: 50, date: manual_anchor_date)

    start_date = Balance::LinkedInvestmentSeriesNormalizer
      .send(:common_supported_history_start_date, [ linked_account.id, manual_account.id ])

    assert_equal linked_activity_date, start_date
  end

  test "common_supported_history_start_date ignores sourced reconciliations on unlinked accounts" do
    linked_account = linked_investment_account
    linked_activity_date = 20.days.ago.to_date
    provider_trade(linked_account, linked_activity_date)

    manual_account = families(:empty).accounts.create!(
      name: "Imported Investment",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    # What an API import session writes for an imported balance update.
    manual_account.entries.create!(
      date: 5.days.ago.to_date,
      name: "Manual value update",
      amount: 1200,
      currency: "USD",
      source: "sure_import_session:#{SecureRandom.uuid}",
      entryable: Valuation.new(kind: "reconciliation")
    )

    start_date = Balance::LinkedInvestmentSeriesNormalizer
      .send(:common_supported_history_start_date, [ linked_account.id, manual_account.id ])

    assert_equal linked_activity_date, start_date
  end

  test "common_supported_history_start_date returns nil when no accounts have provider history" do
    manual_account = families(:empty).accounts.create!(
      name: "Manual Investment",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    manual_account.set_opening_anchor_balance(balance: 50, date: 5.days.ago.to_date)

    start_date = Balance::LinkedInvestmentSeriesNormalizer
      .send(:common_supported_history_start_date, [ manual_account.id ])

    assert_nil start_date
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
    account.family.update!(date_format: "%Y-%m-%d")
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

    normalized = I18n.with_locale(:en) do
      Current.stubs(:family).returns(account.family)

      Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series).normalize
    end

    assert_equal opening_date, normalized.start_date
    assert_equal [ opening_date, 3.days.ago.to_date, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(500, "USD"), normalized.values.first.value
    assert_equal opening_date.strftime("%Y-%m-%d"), normalized.values.first.date_formatted
  end

  test "normalizer resets first point to opening balance when sample lands on exact opening date" do
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
    # Still one point per date (no duplicated anchor), but the first point now
    # carries the balance before the first activity instead of the day's closing balance.
    assert_equal [ opening_date, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(0, "USD"), normalized.values.first.value
    assert_equal Money.new(110, "USD"), normalized.trend.value
  end

  test "normalizer resets first point to zero on daily all-time chart starting at first deposit" do
    account = families(:empty).accounts.create!(
      name: "Linked Daily Exact",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    first_activity_date = 10.days.ago.to_date
    account.entries.create!(
      name: "Initial Deposit",
      date: first_activity_date,
      amount: 4703_99,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    raw_series = Series.new(
      start_date: first_activity_date,
      end_date: Date.current,
      interval: "1 day",
      values: [
        Series::Value.new(date: first_activity_date, date_formatted: "", value: Money.new(4703_99, "USD")),
        Series::Value.new(date: 5.days.ago.to_date, date_formatted: "", value: Money.new(4705_37, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(4705_37, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalizer = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series)
    normalized = normalizer.normalize

    assert_equal first_activity_date, normalized.start_date
    assert_equal [ first_activity_date, 5.days.ago.to_date, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(0, "USD"), normalized.values.first.value
    # "vs. beginning" now measures against the pre-activity balance (#3959).
    assert_equal Money.new(4705_37, "USD"), normalized.trend.value
  end

  test "normalizer resets first point to opening anchor balance when sample lands on anchor date" do
    account = families(:empty).accounts.create!(
      name: "Linked Exact Anchor Date",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    opening_date = 7.days.ago.to_date
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
      start_date: 14.days.ago.to_date,
      end_date: Date.current,
      interval: "1 week",
      values: [
        Series::Value.new(date: 14.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: opening_date, date_formatted: "", value: Money.new(5100, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(5200, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalizer = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series)
    normalized = normalizer.normalize

    assert_equal opening_date, normalized.start_date
    assert_equal [ opening_date, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(5000, "USD"), normalized.values.first.value
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

  test "normalizer uses 0 balance when earlier provider activity predates later opening anchor" do
    account = families(:empty).accounts.create!(
      name: "Early Trade Later Anchor",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    early_trade_date = 15.days.ago.to_date
    later_anchor_date = 8.days.ago.to_date

    account.set_opening_anchor_balance(balance: 5000, date: later_anchor_date)
    account.entries.create!(
      name: "Early Trade",
      date: early_trade_date,
      amount: 100,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    raw_series = Series.new(
      start_date: 20.days.ago.to_date,
      end_date: Date.current,
      interval: "1 week",
      values: [
        Series::Value.new(date: 20.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: 10.days.ago.to_date, date_formatted: "", value: Money.new(100, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(5100, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalizer = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series, view: :balance)
    normalized = normalizer.normalize

    assert_equal early_trade_date, normalized.start_date
    assert_equal [ early_trade_date, 10.days.ago.to_date, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(0, "USD"), normalized.values.first.value
  end

  test "normalizer uses opening anchor balance when opening anchor matches earliest supported history date" do
    account = families(:empty).accounts.create!(
      name: "Anchor Is Earliest",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    anchor_date = 15.days.ago.to_date

    account.set_opening_anchor_balance(balance: 5000, date: anchor_date)
    account.entries.create!(
      name: "Trade on Anchor Date",
      date: anchor_date,
      amount: 100,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    raw_series = Series.new(
      start_date: 20.days.ago.to_date,
      end_date: Date.current,
      interval: "1 week",
      values: [
        Series::Value.new(date: 20.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: 10.days.ago.to_date, date_formatted: "", value: Money.new(5000, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(5100, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalizer = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series, view: :balance)
    normalized = normalizer.normalize

    assert_equal anchor_date, normalized.start_date
    assert_equal [ anchor_date, 10.days.ago.to_date, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(5000, "USD"), normalized.values.first.value
  end

  test "normalizer keeps first point when inception comes from holdings, not activity" do
    account = families(:empty).accounts.create!(
      name: "Linked Holdings First",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account_provider = account.account_providers.create!(provider: coinstats_account)

    # Real pre-existing balance, anchored before the provider started syncing.
    anchor_date = 30.days.ago.to_date
    account.set_opening_anchor_balance(balance: 5000, date: anchor_date)

    # Provider holdings exist, but no posted provider activity yet (only pending).
    holdings_start_date = 10.days.ago.to_date
    security = Security.create!(ticker: "TST", name: "Test")
    Holding.create!(
      account: account,
      security: security,
      date: holdings_start_date,
      qty: 10,
      price: 500,
      amount: 5000,
      currency: "USD",
      account_provider_id: account_provider.id
    )
    account.entries.create!(
      date: holdings_start_date,
      name: "Pending Transaction",
      amount: 100,
      currency: "USD",
      source: "plaid",
      entryable: Transaction.new(extra: { "plaid" => { "pending" => true } })
    )

    raw_series = Series.new(
      start_date: holdings_start_date,
      end_date: Date.current,
      interval: "1 day",
      values: [
        Series::Value.new(date: holdings_start_date, date_formatted: "", value: Money.new(5000, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(5100, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalizer = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series)
    normalized = normalizer.normalize

    # The first point is genuine supported history (no activity on that date),
    # so it must keep its value instead of being reset to 0.
    assert_equal holdings_start_date, normalized.start_date
    assert_equal [ holdings_start_date, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(5000, "USD"), normalized.values.first.value
  end

  test "provider reconciliations before the first activity count as supported history" do
    account = linked_investment_account
    first_reconciliation_date = 20.days.ago.to_date
    provider_reconciliation(account, first_reconciliation_date, 4000)
    provider_reconciliation(account, 15.days.ago.to_date, 4200)
    provider_trade(account, 10.days.ago.to_date)

    assert_equal first_reconciliation_date, Balance::LinkedInvestmentSeriesNormalizer.supported_history_start_date(account)
    assert_equal first_reconciliation_date, Balance::LinkedInvestmentSeriesNormalizer
      .send(:common_supported_history_start_date, [ account.id ])
  end

  test "reconciliations without a provider source do not count as supported history" do
    account = linked_investment_account
    account.entries.create!(
      date: 20.days.ago.to_date,
      name: "Rotated anchor",
      amount: 4000,
      currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    )
    trade_date = 10.days.ago.to_date
    provider_trade(account, trade_date)

    assert_equal trade_date, Balance::LinkedInvestmentSeriesNormalizer.supported_history_start_date(account)
  end

  # A data import tags its valuations with its session, and the account it
  # made can be linked afterwards; a provider's reconciliation from before
  # the link still counts.
  test "valuations a data import recorded do not count as supported history" do
    account = linked_investment_account
    account.entries.create!(
      date: 40.days.ago.to_date,
      name: "Imported balance",
      amount: 3000,
      currency: "USD",
      source: "#{Family::DataImporter::SESSION_SOURCE_PREFIX}#{SecureRandom.uuid}",
      entryable: Valuation.new(kind: "reconciliation")
    )
    first_reconciliation_date = 20.days.ago.to_date
    provider_reconciliation(account, first_reconciliation_date, 4000)
    account.account_providers.update_all(created_at: 10.days.ago)

    assert_equal first_reconciliation_date, Balance::LinkedInvestmentSeriesNormalizer.supported_history_start_date(account)
    assert_equal first_reconciliation_date, Balance::LinkedInvestmentSeriesNormalizer
      .send(:common_supported_history_start_date, [ account.id ])
  end

  test "a series starting on a provider reconciliation keeps its recorded first value" do
    account = linked_investment_account
    first_reconciliation_date = 20.days.ago.to_date
    provider_reconciliation(account, first_reconciliation_date, 4000)
    provider_trade(account, first_reconciliation_date)

    raw_series = Series.new(
      start_date: 30.days.ago.to_date,
      end_date: Date.current,
      interval: "1 day",
      values: [
        Series::Value.new(date: 30.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: first_reconciliation_date, date_formatted: "", value: Money.new(4000, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(4500, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalized = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series).normalize

    assert_equal [ first_reconciliation_date, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(4000, "USD"), normalized.values.first.value
  end

  test "coarse sampling past a provider reconciliation adds no synthetic opening point" do
    account = linked_investment_account
    first_reconciliation_date = 20.days.ago.to_date
    provider_reconciliation(account, first_reconciliation_date, 4000)
    provider_trade(account, 10.days.ago.to_date)

    raw_series = Series.new(
      start_date: 30.days.ago.to_date,
      end_date: Date.current,
      interval: "1 week",
      values: [
        Series::Value.new(date: 30.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: 16.days.ago.to_date, date_formatted: "", value: Money.new(4100, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(4500, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalized = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series).normalize

    assert_equal [ 16.days.ago.to_date, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(4100, "USD"), normalized.values.first.value
  end

  private

    def linked_investment_account
      account = families(:empty).accounts.create!(
        name: "Linked Investment",
        balance: 0,
        currency: "USD",
        accountable: Investment.new
      )
      coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
      coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
      account.account_providers.create!(provider: coinstats_account)
      account
    end

    def provider_reconciliation(account, date, amount)
      account.entries.create!(
        date: date,
        name: "Reconciliation",
        amount: amount,
        currency: "USD",
        source: "etoro",
        entryable: Valuation.new(kind: "reconciliation")
      )
    end

    def provider_trade(account, date)
      account.entries.create!(
        date: date,
        name: "Trade",
        amount: 100,
        currency: "USD",
        source: "etoro",
        entryable: Transaction.new
      )
    end
end
