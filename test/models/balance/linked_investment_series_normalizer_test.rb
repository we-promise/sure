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

  test "Fineco history activity does not predate the first observed provider holding snapshot" do
    account = families(:empty).accounts.create!(
      name: "Fineco History Boundary",
      balance: 0,
      currency: "EUR",
      accountable: Investment.new
    )
    item = account.family.coinstats_items.create!(name: "Provider", api_key: "test-key")
    provider_account = item.coinstats_accounts.create!(name: "Provider Investment", currency: "EUR")
    account_provider = account.account_providers.create!(provider: provider_account)
    history_date = 3.years.ago.to_date
    snapshot_date = 6.months.ago.to_date
    security = Security.create!(ticker: "FINECO-HISTORY-BOUNDARY", name: "Fineco history boundary")

    history_entry = account.entries.create!(
      name: "Fineco historical purchase",
      date: history_date,
      amount: 100,
      currency: "EUR",
      source: "fineco",
      external_id: "#{Trade::FINECO_HISTORY_EXTERNAL_ID_PREFIX}purchase",
      entryable: Trade.new(
        qty: 2,
        security: security,
        price: 50,
        currency: "EUR",
        investment_activity_label: "Buy",
        extra: {
          "fineco" => {
            "history_schema_version" => Trade::FINECO_HISTORY_SCHEMA_VERSION,
            "provider_account_id" => provider_account.id,
            "cash_account_external" => true
          }
        }
      )
    )
    assert history_entry.entryable.fineco_history_entry?(history_entry)
    assert_includes Trade.fineco_history.ids, history_entry.entryable_id
    Holding.create!(
      account: account,
      security: security,
      date: snapshot_date,
      qty: 2,
      price: 250,
      amount: 500,
      currency: "EUR",
      account_provider_id: account_provider.id
    )

    raw_series = Series.new(
      start_date: history_date,
      end_date: Date.current,
      interval: "1 day",
      values: [
        Series::Value.new(date: history_date, date_formatted: "", value: Money.new(0, "EUR")),
        Series::Value.new(date: snapshot_date, date_formatted: "", value: Money.new(500, "EUR")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(550, "EUR"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalized = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series).normalize
    common_start_date = Balance::LinkedInvestmentSeriesNormalizer
      .send(:common_supported_history_start_date, [ account.id ])

    assert_equal snapshot_date, normalized.start_date
    assert_equal [ snapshot_date, Date.current ], normalized.values.map(&:date)
    assert_equal Money.new(500, "EUR"), normalized.values.first.value
    assert_equal snapshot_date, common_start_date
  end

  test "Directa history activity is excluded from supported history before its first snapshot" do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    owner = users(:family_admin)
    account = owner.family.accounts.create!(
      name: "Directa history chart boundary",
      balance: 200,
      currency: "EUR",
      accountable: Investment.new,
      owner: owner
    )
    history_date = Date.new(2021, 4, 5)
    snapshot_date = 6.months.ago.to_date
    item = DirectaItem.create!(
      family: owner.family,
      owner: owner,
      broker_account: "00123",
      account_identity: "00123",
      multi_token: "synthetic-multi-token",
      mono_token: "synthetic-mono-token",
      connection_generation: 1,
      status: :connected,
      portfolio_snapshot_at: snapshot_date.in_time_zone + 12.hours
    )
    provider_account = item.directa_accounts.create!(currency: "EUR")
    provider_link = account.account_providers.create!(provider: provider_account)
    security = Security.create!(ticker: "DIRECTA-CHART-BOUNDARY", name: "Directa chart boundary")
    Holding.create!(
      account: account,
      account_provider: provider_link,
      security: security,
      date: snapshot_date,
      qty: 2,
      price: 100,
      amount: 200,
      currency: "EUR"
    )
    external_id = "#{Trade::DIRECTA_HISTORY_EXTERNAL_ID_PREFIX}#{'c' * 64}"
    fingerprint = "a" * 64
    bank_scope = "b" * 64
    provider_account.update!(
      history_ledger: {
        "schema_version" => 1,
        "bank_scope" => bank_scope,
        "coverage_start" => history_date.iso8601,
        "coverage_end" => history_date.iso8601,
        "cohorts" => { history_date.iso8601 => { fingerprint => 1 } },
        "entries" => { external_id => { "fingerprint" => fingerprint, "date" => history_date.iso8601 } }
      }
    )
    entry = account.entries.create!(
      name: "Old Directa purchase",
      date: history_date,
      amount: 100,
      currency: "EUR",
      source: "directa",
      external_id: external_id,
      entryable: Trade.new(
        security: security,
        qty: 2,
        price: 50,
        currency: "EUR",
        investment_activity_label: "Buy",
        extra: {
          "directa" => {
            "history_schema_version" => Trade::DIRECTA_HISTORY_SCHEMA_VERSION,
            "provider_account_id" => provider_account.id,
            "fingerprint" => fingerprint,
            "bank_scope" => bank_scope,
            "aggregation" => Trade::DIRECTA_HISTORY_AGGREGATION
          }
        }
      )
    )

    assert entry.entryable.directa_history_entry?(entry)
    assert_empty Balance::LinkedInvestmentSeriesNormalizer.provider_activity_entries(account.entries).to_a
    assert_equal snapshot_date, Balance::LinkedInvestmentSeriesNormalizer
      .new(account: account, series: nil)
      .supported_history_start_date
  end

  test "cash-only Directa snapshot supplies chart inception without any holdings" do
    owner = users(:family_admin)
    account = owner.family.accounts.create!(
      name: "Directa cash-only chart boundary",
      balance: 250,
      cash_balance: 250,
      currency: "EUR",
      accountable: Investment.new,
      owner: owner
    )
    snapshot_date = 6.months.ago.to_date
    item = DirectaItem.create!(
      family: owner.family,
      owner: owner,
      portfolio_snapshot_at: snapshot_date.in_time_zone + 12.hours
    )
    provider_account = item.directa_accounts.create!(currency: "EUR")
    account.account_providers.create!(provider: provider_account)
    old_date = Date.new(2021, 4, 5)
    raw_series = Series.new(
      start_date: old_date,
      end_date: Date.current,
      interval: "1 day",
      values: [
        Series::Value.new(date: old_date, date_formatted: "", value: Money.new(0, "EUR")),
        Series::Value.new(date: snapshot_date, date_formatted: "", value: Money.new(250, "EUR")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(250, "EUR"))
      ],
      favorable_direction: account.favorable_direction
    )

    normalized = Balance::LinkedInvestmentSeriesNormalizer.new(account: account, series: raw_series).normalize

    assert_equal snapshot_date, normalized.start_date
    assert_equal [ snapshot_date, Date.current ], normalized.values.map(&:date)
    assert_equal snapshot_date, Balance::LinkedInvestmentSeriesNormalizer
      .send(:common_supported_history_start_date, [ account.id ])
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
end
