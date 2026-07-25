require "test_helper"

class SnaptradeAccountProcessorTest < ActiveSupport::TestCase
  fixtures :families, :snaptrade_items, :snaptrade_accounts, :accounts, :securities

  setup do
    @family = families(:dylan_family)
    @snaptrade_item = snaptrade_items(:configured_item)
    @snaptrade_account = snaptrade_accounts(:fidelity_401k)

    # Create and link a Sure investment account
    @account = @family.accounts.create!(
      name: "Test Investment",
      balance: 50000,
      cash_balance: 1500,
      currency: "USD",
      accountable: Investment.new
    )
    @snaptrade_account.ensure_account_provider!(@account)
    @snaptrade_account.reload
  end

  # === HoldingsProcessor Tests ===

  test "holdings processor creates holdings from raw payload" do
    security = securities(:aapl)

    @snaptrade_account.update!(
      raw_holdings_payload: [
        {
          "symbol" => {
            "symbol" => { "symbol" => security.ticker, "description" => security.name }
          },
          "units" => "100.5",
          "price" => "150.25",
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account)
    processor.process

    holding = @account.holdings.find_by(security: security)
    assert_not_nil holding
    assert_equal BigDecimal("100.5"), holding.qty
    assert_equal BigDecimal("150.25"), holding.price
  end

  test "holdings processor stores cost basis when available" do
    security = securities(:aapl)

    @snaptrade_account.update!(
      raw_holdings_payload: [
        {
          "symbol" => {
            "symbol" => { "symbol" => security.ticker, "description" => security.name }
          },
          "units" => "50",
          "price" => "175.00",
          "average_purchase_price" => "125.50",
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account)
    processor.process

    holding = @account.holdings.find_by(security: security)
    assert_not_nil holding
    assert_equal BigDecimal("125.50"), holding.cost_basis
    assert_equal "provider", holding.cost_basis_source
  end

  test "holdings processor does not overwrite manual cost basis" do
    security = securities(:aapl)

    # Create holding with manual cost basis
    holding = @account.holdings.create!(
      security: security,
      date: Date.current,
      currency: "USD",
      qty: 50,
      price: 175.00,
      amount: 8750.00,
      cost_basis: 100.00,
      cost_basis_source: "manual"
    )

    @snaptrade_account.update!(
      raw_holdings_payload: [
        {
          "symbol" => {
            "symbol" => { "symbol" => security.ticker }
          },
          "units" => "50",
          "price" => "175.00",
          "average_purchase_price" => "125.50",
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account)
    processor.process

    holding.reload
    assert_equal BigDecimal("100.00"), holding.cost_basis
    assert_equal "manual", holding.cost_basis_source
  end

  test "holdings processor skips entries without ticker" do
    @snaptrade_account.update!(
      raw_holdings_payload: [
        {
          "symbol" => { "symbol" => {} },  # Missing ticker
          "units" => "100",
          "price" => "50.00"
        }
      ]
    )

    processor = SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account)

    assert_nothing_raised do
      processor.process
    end
    assert_equal 0, @account.holdings.count
  end

  test "processor trusts API total for multi-currency holdings" do
    security = securities(:aapl)
    Account.any_instance.stubs(:set_current_balance)

    @snaptrade_account.update!(
      currency: "CHF",
      current_balance: BigDecimal("15000.00"),
      cash_balance: BigDecimal("1000.00"),
      raw_holdings_payload: [
        {
          "symbol" => {
            "symbol" => { "symbol" => security.ticker, "description" => security.name }
          },
          "units" => "10",
          "price" => "150.00",
          "currency" => "USD",
          "average_purchase_price" => "125.50"
        }
      ],
      raw_activities_payload: []
    )

    SnaptradeAccount::Processor.new(@snaptrade_account).process

    @account.reload
    assert_equal BigDecimal("15000.00"), @account.balance
    assert_equal BigDecimal("1000.00"), @account.cash_balance
    assert_equal "CHF", @account.currency
  end

  # === ActivitiesProcessor Tests ===

  test "activities processor maps BUY type to Buy label" do
    security = securities(:aapl)

    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "id" => "activity_buy_1",
          "type" => "BUY",
          "symbol" => { "symbol" => security.ticker, "description" => security.name },
          "units" => "10",
          "price" => "150.00",
          "amount" => "1500.00",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    result = processor.process

    assert_equal 1, result[:trades]
    trade_entry = @account.entries.find_by(external_id: "activity_buy_1")
    assert_not_nil trade_entry
    assert_equal "Buy", trade_entry.entryable.investment_activity_label
  end

  test "activities processor maps SELL type with negative quantity" do
    security = securities(:aapl)

    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "id" => "activity_sell_1",
          "type" => "SELL",
          "symbol" => { "symbol" => security.ticker },
          "units" => "5",
          "price" => "175.00",
          "amount" => "875.00",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    result = processor.process

    assert_equal 1, result[:trades]
    trade_entry = @account.entries.find_by(external_id: "activity_sell_1")
    assert trade_entry.entryable.qty.negative?
    assert_equal "Sell", trade_entry.entryable.investment_activity_label
  end

  test "activities processor handles DIVIDEND as cash transaction" do
    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "id" => "activity_div_1",
          "type" => "DIVIDEND",
          "symbol" => { "symbol" => "AAPL" },
          "amount" => "25.50",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD",
          "description" => "AAPL Dividend Payment"
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    tx_entry = @account.entries.find_by(external_id: "activity_div_1")
    assert_not_nil tx_entry
    assert_equal "Transaction", tx_entry.entryable_type
    assert_equal "Dividend", tx_entry.entryable.investment_activity_label
  end

  test "activities processor normalizes withdrawal as positive outflow amount" do
    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "id" => "activity_withdraw_1",
          "type" => "WITHDRAWAL",
          "amount" => "1000.00",  # Provider sends positive
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    tx_entry = @account.entries.find_by(external_id: "activity_withdraw_1")
    assert_equal 1000.00, tx_entry.amount.to_f
  end

  test "activities processor skips activities without external_id" do
    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "type" => "DIVIDEND",
          "amount" => "50.00"
          # Missing "id" field
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    result = processor.process

    assert_equal 0, result[:transactions]
    assert_equal 0, result[:trades]
  end

  test "activities processor handles unmapped types as Other" do
    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "id" => "activity_unknown_1",
          "type" => "UNKNOWN_TYPE_XYZ",
          "amount" => "100.00",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    tx_entry = @account.entries.find_by(external_id: "activity_unknown_1")
    assert_equal "Other", tx_entry.entryable.investment_activity_label
  end

  test "activities processor is idempotent with same external_id" do
    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "id" => "activity_idempotent_1",
          "type" => "DIVIDEND",
          "amount" => "75.00",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process
    processor.process  # Process again

    entries = @account.entries.where(external_id: "activity_idempotent_1")
    assert_equal 1, entries.count
  end

  # === Multi-currency cash (issue #1809) ===

  test "upsert_balances! persists all entries and keeps the primary currency in cash_balance" do
    @snaptrade_account.update!(currency: "USD")

    # Primary (USD) is intentionally NOT first so this asserts the
    # account-currency selection actually resolves it via dig(:currency, :code)
    # on the string-keyed payload — not the `entries.first` fallback.
    @snaptrade_account.upsert_balances!([
      { "currency" => { "code" => "EUR" }, "cash" => "800.00" },
      { "currency" => { "code" => "USD" }, "cash" => "1500.00" }
    ])

    @snaptrade_account.reload
    assert_equal BigDecimal("1500.00"), @snaptrade_account.cash_balance, "primary (USD) cash stays in cash_balance"
    assert_equal 2, @snaptrade_account.raw_balances_payload.size, "all balance entries are persisted, not just the primary"

    non_primary = @snaptrade_account.non_primary_cash_entries
    assert_equal 1, non_primary.size
    assert_equal "EUR", non_primary.first[:currency]
  end

  test "holdings processor surfaces non-primary-currency cash as a synthetic holding" do
    @snaptrade_account.update!(
      currency: "USD",
      cash_balance: BigDecimal("1500.00"),
      raw_balances_payload: [
        { "currency" => { "code" => "USD" }, "cash" => "1500.00" },
        { "currency" => { "code" => "EUR" }, "cash" => "800.00" }
      ]
    )

    SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account).process

    eur_cash = @account.holdings.joins(:security).where(securities: { kind: "cash" }, currency: "EUR").order(date: :desc).first
    assert_not_nil eur_cash, "EUR cash must be imported as a synthetic cash holding"
    assert_equal BigDecimal("800"), eur_cash.qty
    assert eur_cash.security.cash?, "the holding's security is a synthetic cash security"

    usd_cash = @account.holdings.joins(:security).where(securities: { kind: "cash" }, currency: "USD").exists?
    assert_not usd_cash, "primary (USD) cash stays in cash_balance, not duplicated as a holding"
  end

  test "processor surfaces non-primary cash even when there are no security holdings" do
    @snaptrade_account.update!(
      currency: "USD",
      raw_holdings_payload: [],
      raw_balances_payload: [
        { "currency" => { "code" => "USD" }, "cash" => "1500.00" },
        { "currency" => { "code" => "EUR" }, "cash" => "800.00" }
      ]
    )

    SnaptradeAccount::Processor.new(@snaptrade_account).process

    eur_cash = @account.holdings.joins(:security).where(securities: { kind: "cash" }, currency: "EUR").exists?
    assert eur_cash, "processor must run the holdings processor so secondary-currency cash is surfaced even with no stock holdings"
  end

  # === Cash-equivalent positions (money market / sweep funds) ===
  #
  # SnapTrade includes money market funds in the balances endpoint's `cash`
  # figure AND returns them as positions with `cash_equivalent: true`.
  # Counting both inflates the account total (e.g. Fidelity SPAXX).

  test "processor does not double count cash-equivalent positions included in cash balance" do
    security = securities(:aapl)
    Account.any_instance.stubs(:set_current_balance)

    @snaptrade_account.update!(
      currency: "USD",
      cash_balance: BigDecimal("5000.00"),
      raw_holdings_payload: [
        {
          "symbol" => {
            "symbol" => { "symbol" => "SPAXX", "description" => "Fidelity Government Money Market Fund" }
          },
          "units" => "4000",
          "price" => "1.00",
          "currency" => "USD",
          "cash_equivalent" => true
        },
        {
          "symbol" => {
            "symbol" => { "symbol" => security.ticker, "description" => security.name }
          },
          "units" => "10",
          "price" => "150.00",
          "currency" => "USD"
        }
      ],
      raw_activities_payload: []
    )

    SnaptradeAccount::Processor.new(@snaptrade_account).process

    @account.reload
    assert_equal BigDecimal("1000.00"), @account.cash_balance, "cash-equivalent position value must be subtracted from cash"
    assert_equal BigDecimal("6500.00"), @account.balance, "total must count the money market fund only once (1500 stock + 4000 MMF + 1000 cash)"

    spaxx = @account.holdings.joins(:security).where(securities: { ticker: "SPAXX" }).order(date: :desc).first
    assert_not_nil spaxx, "the cash-equivalent position is still imported as a holding"
    assert_equal BigDecimal("4000"), spaxx.amount

    debug_entries = DebugLogEntry.where(category: "provider_sync", provider_key: "snaptrade")
    assert_equal 1, debug_entries.count, "the exclusion is recorded once in /settings/debug"
    assert_equal "4000.0", debug_entries.first.metadata["cash_equivalent_value"]
  end

  test "cash balance may go negative when cash-equivalent value exceeds reported cash and is recorded for support" do
    Account.any_instance.stubs(:set_current_balance)

    # A stale holdings snapshot (or real margin) can make the cash-equivalent
    # value exceed reported cash. No floor is applied — negative cash is
    # legitimate for margin — but before/after values are recorded so support
    # can tell the two apart in /settings/debug.
    @snaptrade_account.update!(
      currency: "USD",
      cash_balance: BigDecimal("100.00"),
      raw_holdings_payload: [
        {
          "symbol" => {
            "symbol" => { "symbol" => "SPAXX", "description" => "Fidelity Government Money Market Fund" }
          },
          "units" => "4000",
          "price" => "1.00",
          "currency" => "USD",
          "cash_equivalent" => true
        }
      ],
      raw_activities_payload: []
    )

    SnaptradeAccount::Processor.new(@snaptrade_account).process

    @account.reload
    assert_equal BigDecimal("-3900.00"), @account.cash_balance, "negative cash is preserved, not floored"

    entry = DebugLogEntry.where(category: "provider_sync", provider_key: "snaptrade").order(created_at: :desc).first
    assert_equal "100.0", entry.metadata["cash_balance_before"]
    assert_equal "-3900.0", entry.metadata["cash_balance_after"]
  end

  test "cash-equivalent positions are subtracted in the stored cash currency when it falls back to USD" do
    Account.any_instance.stubs(:set_current_balance)

    # CAD account with no CAD cash entry: upsert_balances!' USD fallback means
    # cash_balance is denominated in USD, so the USD money market fund must be
    # subtracted from it even though it doesn't match the account currency.
    @snaptrade_account.update!(
      currency: "CAD",
      current_balance: BigDecimal("10000.00"),
      cash_balance: BigDecimal("5000.00"),
      raw_balances_payload: [
        { "currency" => { "code" => "USD" }, "cash" => "5000.00" }
      ],
      raw_holdings_payload: [
        {
          "symbol" => {
            "symbol" => { "symbol" => "SPAXX", "description" => "Fidelity Government Money Market Fund" }
          },
          "units" => "4000",
          "price" => "1.00",
          "currency" => "USD",
          "cash_equivalent" => true
        }
      ],
      raw_activities_payload: []
    )

    SnaptradeAccount::Processor.new(@snaptrade_account).process

    @account.reload
    assert_equal BigDecimal("1000.00"), @account.cash_balance, "USD cash-equivalent position must be subtracted from the USD-denominated cash balance"
    assert_equal BigDecimal("10000.00"), @account.balance, "multi-currency holdings still use the API total"
  end

  test "cash-equivalent positions in a non-primary currency reduce that currency's synthetic cash holding" do
    @snaptrade_account.update!(
      currency: "USD",
      cash_balance: BigDecimal("1500.00"),
      raw_balances_payload: [
        { "currency" => { "code" => "USD" }, "cash" => "1500.00" },
        { "currency" => { "code" => "EUR" }, "cash" => "800.00" }
      ],
      raw_holdings_payload: [
        {
          "symbol" => {
            "symbol" => { "symbol" => "EURMM", "description" => "Euro Money Market Fund" }
          },
          "units" => "300",
          "price" => "1.00",
          "currency" => "EUR",
          "cash_equivalent" => true
        }
      ]
    )

    SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account).process

    eur_cash = @account.holdings.joins(:security).where(securities: { kind: "cash" }, currency: "EUR").order(date: :desc).first
    assert_not_nil eur_cash
    assert_equal BigDecimal("500"), eur_cash.qty, "EUR synthetic cash must exclude the EUR cash-equivalent position (800 - 300)"

    eur_mmf = @account.holdings.joins(:security).where(securities: { ticker: "EURMM" }).order(date: :desc).first
    assert_not_nil eur_mmf, "the EUR cash-equivalent position is still imported as a holding"
  end

  test "non-primary cash holding is not duplicated across repeated syncs" do
    @snaptrade_account.update!(
      currency: "USD",
      raw_balances_payload: [
        { "currency" => { "code" => "USD" }, "cash" => "1500.00" },
        { "currency" => { "code" => "EUR" }, "cash" => "800.00" }
      ]
    )

    2.times { SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account).process }

    eur_cash = @account.holdings.joins(:security).where(securities: { kind: "cash" }, currency: "EUR")
    assert_equal 1, eur_cash.select(:external_id).distinct.count
  end
end
