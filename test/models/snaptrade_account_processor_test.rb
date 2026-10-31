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

  # === /positions/all payload shape ===

  test "holdings processor creates holdings from a positions/all payload" do
    security = securities(:aapl)

    @snaptrade_account.update!(
      raw_holdings_payload: [
        {
          "instrument" => {
            "kind" => "stock",
            "symbol" => security.ticker,
            "raw_symbol" => security.ticker,
            "description" => security.name,
            "currency" => "USD",
            "exchange" => "XNAS"
          },
          "units" => "10",
          "price" => "77.885",
          "cost_basis" => "30",
          "currency" => "USD"
        }
      ]
    )

    SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account).process

    holding = @account.holdings.find_by(security: security)
    assert_not_nil holding
    assert_equal BigDecimal("10"), holding.qty
    assert_equal BigDecimal("77.885"), holding.price
  end

  test "holdings processor reads cost_basis as a per-share value" do
    security = securities(:aapl)

    @snaptrade_account.update!(
      raw_holdings_payload: [
        {
          "instrument" => { "kind" => "stock", "symbol" => security.ticker, "currency" => "USD" },
          "units" => "10",
          "price" => "77.885",
          "cost_basis" => "30",
          "currency" => "USD"
        }
      ]
    )

    SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account).process

    holding = @account.holdings.find_by(security: security)
    assert_not_nil holding
    assert_equal BigDecimal("30"), holding.cost_basis
    assert_equal "provider", holding.cost_basis_source
  end

  test "cash-equivalent positions are recognised in a positions/all payload" do
    security = securities(:aapl)

    @snaptrade_account.update!(
      currency: "USD",
      cash_balance: BigDecimal("1000.00"),
      raw_holdings_payload: [
        {
          "instrument" => { "kind" => "mutualfund", "symbol" => security.ticker, "currency" => "USD" },
          "units" => "100",
          "price" => "1.00",
          "currency" => "USD",
          "cash_equivalent" => true
        }
      ]
    )

    assert_equal BigDecimal("100"), @snaptrade_account.cash_equivalent_position_value("USD")
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

  test "activities processor handles SPLIT as zero-amount trade" do
    security = securities(:aapl)

    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "id" => "activity_split_1",
          "type" => "SPLIT",
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
    trade_entry = @account.entries.find_by(external_id: "activity_split_1")
    assert_not_nil trade_entry
    assert_equal "Other", trade_entry.entryable.investment_activity_label
    assert_equal 10, trade_entry.entryable.qty
    assert_equal 0.0, trade_entry.amount.to_f
  end

  test "activities processor handles internal cash transfers with proper inflow and outflow signs" do
    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "id" => "activity_xfer_in_1",
          "type" => "INTERNAL_CASH_TRANSFER_IN",
          "amount" => "500.00",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        },
        {
          "id" => "activity_xfer_out_1",
          "type" => "INTERNAL_CASH_TRANSFER_OUT",
          "amount" => "200.00",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    result = processor.process

    assert_equal 2, result[:transactions]
    in_entry = @account.entries.find_by(external_id: "activity_xfer_in_1")
    assert_equal "Transfer", in_entry.entryable.investment_activity_label
    assert_equal(-500.00, in_entry.amount.to_f)

    out_entry = @account.entries.find_by(external_id: "activity_xfer_out_1")
    assert_equal "Transfer", out_entry.entryable.investment_activity_label
    assert_equal 200.00, out_entry.amount.to_f
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

  # === Full Account Sync Integration ===

  test "processor synchronizes balances, holdings, and activities end-to-end without cash distortion" do
    security = securities(:aapl)

    @snaptrade_account.update!(
      currency: "USD",
      current_balance: BigDecimal("5000.00"),
      cash_balance: BigDecimal("1500.00"),
      raw_holdings_payload: [
        {
          "symbol" => {
            "symbol" => { "symbol" => security.ticker, "description" => security.name }
          },
          "units" => "20",
          "price" => "175.00",
          "currency" => "USD"
        }
      ],
      raw_activities_payload: [
        {
          "id" => "activity_full_split",
          "type" => "SPLIT",
          "symbol" => { "symbol" => security.ticker },
          "units" => "10",
          "price" => "175.00",
          "amount" => "1750.00",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        },
        {
          "id" => "activity_full_xfer",
          "type" => "INTERNAL_CASH_TRANSFER_IN",
          "amount" => "300.00",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        }
      ]
    )

    result = SnaptradeAccount::Processor.new(@snaptrade_account).process

    assert result[:holdings_processed]
    assert result[:activities_processed]

    @account.reload
    assert_equal BigDecimal("5000.00"), @account.balance
    assert_equal BigDecimal("1500.00"), @account.cash_balance

    holding = @account.holdings.find_by(security: security)
    assert_not_nil holding
    assert_equal BigDecimal("20"), holding.qty

    split_entry = @account.entries.find_by(external_id: "activity_full_split")
    assert_not_nil split_entry
    assert_equal "Other", split_entry.entryable.investment_activity_label
    assert_equal 0.0, split_entry.amount.to_f

    xfer_entry = @account.entries.find_by(external_id: "activity_full_xfer")
    assert_not_nil xfer_entry
    assert_equal "Transfer", xfer_entry.entryable.investment_activity_label
    assert_equal(-300.00, xfer_entry.amount.to_f)
  end

  test "processor cleanly reclassifies pre-existing activity from transaction to trade on resync" do
    security = securities(:aapl)

    # 1. Simulate an entry already synced as a Transaction under old code
    stale_entry = @account.entries.create!(
      external_id: "resync_split_001",
      source: "snaptrade",
      amount: 1750.00,
      currency: "USD",
      date: Date.current,
      name: "DISTRIBUTION AAPL",
      entryable: Transaction.new(investment_activity_label: "Other")
    )
    stale_id = stale_entry.id

    # 2. Configure raw payloads for the next sync
    @snaptrade_account.update!(
      raw_holdings_payload: [],
      raw_activities_payload: [
        {
          "id" => "resync_split_001",
          "type" => "SPLIT",
          "symbol" => { "symbol" => security.ticker },
          "units" => "10",
          "price" => "0.0",
          "amount" => "1750.00",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        }
      ]
    )

    # 3. Run full account processor
    result = SnaptradeAccount::Processor.new(@snaptrade_account).process

    assert result[:activities_processed]

    # 4. Verify stale entry was reclassified to Trade
    entry = @account.entries.find_by(external_id: "resync_split_001", source: "snaptrade")
    assert_not_nil entry
    assert_not_equal stale_id, entry.id
    assert entry.entryable.is_a?(Trade)
    assert_equal BigDecimal("10"), entry.entryable.qty
    assert_equal 0.0, entry.amount.to_f
    assert_equal 0.0, entry.entryable.price.to_f
  end

  test "reverse-synced history holds shares deposited as OTHER only until they are sold" do
    # Twice, shares vest with no price and no cash, are sold, and the proceeds
    # leave the account; nothing is held now. The second deposit settles before
    # its trade date.
    @snaptrade_account.update!(
      current_balance: 0,
      cash_balance: 0,
      raw_holdings_payload: [],
      raw_activities_payload: [
        snaptrade_activity("vest_1", "OTHER", 40, units: 10, price: 0, amount: 0),
        snaptrade_activity("sale_1", "SELL", 39, units: -10, price: 100, amount: 1000),
        snaptrade_activity("payout_1", "TRANSFER", 37, amount: -1000),
        snaptrade_activity("vest_2", "OTHER", 20, trade_days_ago: 17, units: 5, price: 0, amount: 0),
        snaptrade_activity("sale_2", "SELL", 16, units: -5, price: 90, amount: 449, fee: 1),
        snaptrade_activity("payout_2", "TRANSFER", 14, amount: -449)
      ]
    )

    reverse_sync!

    held = [ 41, 40, 39, 30, 21, 20, 17, 16, 0 ].index_with { |days_ago| held_qty(days_ago) }
    assert_equal({ 41 => 0, 40 => 10, 39 => 0, 30 => 0, 21 => 0, 20 => 5, 17 => 5, 16 => 0, 0 => 0 }, held)

    # With no market prices, a deposit day is valued at the nearest price the
    # account has: the first at the sale that follows it, the second at the
    # last one before it.
    balance = [ 41, 40, 39, 38, 37, 30, 20, 17, 16, 15, 14, 0 ].index_with { |days_ago| balance_on(days_ago) }
    assert_equal({ 41 => 0, 40 => 1000, 39 => 1000, 38 => 1000, 37 => 0, 30 => 0, 20 => 500, 17 => 500, 16 => 449, 15 => 449, 14 => 0, 0 => 0 }, balance,
                 "the shares until their sale, then the proceeds until they leave")
    assert_no_negative_history

    sale = @account.entries.find_by!(external_id: "sale_1").entryable
    assert_nil sale.realized_gain_loss, "shares that arrived at no known cost claim no gain when sold"

    synced_once = synced_series
    reverse_sync!
    assert_equal synced_once, synced_series, "a second sync changes nothing"
  end

  test "a position held across a share movement at no price keeps its value without market prices" do
    @snaptrade_account.update!(
      current_balance: 10945,
      cash_balance: 0,
      raw_holdings_payload: [ snaptrade_position("RSUCO", 99.5, 110) ],
      raw_activities_payload: [
        snaptrade_activity("deposit", "CONTRIBUTION", 61, amount: 10000),
        snaptrade_activity("buy", "BUY", 60, units: 100, price: 100, amount: -10000),
        snaptrade_activity("removed", "OTHER", 30, units: -0.5, price: 0, amount: 0)
      ]
    )

    reverse_sync!

    assert_equal BigDecimal("100"), held_qty(31)
    assert_equal BigDecimal("99.5"), held_qty(30)
    assert_equal 9950, holdings_value(30), "valued at the last price the account has, not at the movement's zero"
    assert_equal 9950, holdings_value(1)
  end

  test "shares kept from a vest with a same-day sell-to-cover are valued at the sale price" do
    @snaptrade_account.update!(
      current_balance: 3600,
      cash_balance: 0,
      raw_holdings_payload: [ snaptrade_position("RSUCO", 60, 60) ],
      raw_activities_payload: [
        snaptrade_activity("vest", "OTHER", 30, units: 100, price: 0, amount: 0),
        snaptrade_activity("sell_to_cover", "SELL", 30, units: -40, price: 50, amount: 2000),
        snaptrade_activity("tax_out", "TRANSFER", 29, amount: -2000)
      ]
    )

    reverse_sync!

    assert_equal BigDecimal("0"), held_qty(31)
    assert_equal BigDecimal("60"), held_qty(30)
    assert_equal 3000, holdings_value(30), "the deposit's zero is not the day's price"
    assert_equal 3000, holdings_value(1)
  end

  test "a same-day journal out and back in leaves the cost basis and realized gain alone" do
    @snaptrade_account.update!(
      current_balance: 12500,
      cash_balance: 6000,
      raw_holdings_payload: [ snaptrade_position("RSUCO", 50, 130) ],
      raw_activities_payload: [
        snaptrade_activity("deposit", "CONTRIBUTION", 61, amount: 10000),
        snaptrade_activity("buy", "BUY", 60, units: 100, price: 100, amount: -10000),
        snaptrade_activity("journal_out", "JOURNAL", 30, units: -100, price: 110, amount: 0),
        snaptrade_activity("journal_in", "JOURNAL", 30, units: 100, price: 110, amount: 0),
        snaptrade_activity("sale", "SELL", 10, units: -50, price: 120, amount: 6000)
      ]
    )

    reverse_sync!

    assert_equal BigDecimal("100"), @account.holdings.find_by!(date: 20.days.ago.to_date).cost_basis
    gain = @account.entries.find_by!(external_id: "sale").entryable.realized_gain_loss
    assert_equal Money.new(1000, "USD"), gain&.value
  end

  test "shares deposited as OTHER and moved out as TRANSFER both move the history" do
    security = Security.create!(ticker: "RSUCO", name: "RSU Co")
    (71.days.ago.to_date..Date.current).each { |date| Security::Price.create!(security: security, date: date, price: 100) }

    @snaptrade_account.update!(
      current_balance: 100,
      cash_balance: 100,
      raw_holdings_payload: [],
      raw_activities_payload: [
        snaptrade_activity("deposit", "CONTRIBUTION", 70, amount: 100),
        snaptrade_activity("vest", "OTHER", 40, units: 10, price: 0, amount: 0),
        snaptrade_activity("moved_out", "TRANSFER", 35, units: -10, price: 0)
      ]
    )

    reverse_sync!

    held = [ 50, 41, 40, 36, 35, 0 ].index_with { |days_ago| held_qty(days_ago) }
    assert_equal({ 50 => 0, 41 => 0, 40 => 10, 36 => 10, 35 => 0, 0 => 0 }, held)
    assert_equal 100, balance_on(50)
    assert_equal 1100, balance_on(38)
    assert_no_negative_history
  end

  test "a deposit dated after the sale of its own shares does not leave negative holdings" do
    @snaptrade_account.update!(
      current_balance: 0,
      cash_balance: 0,
      raw_holdings_payload: [],
      raw_activities_payload: [
        snaptrade_activity("vest", "OTHER", 28, trade_days_ago: 30, units: 10, price: 0, amount: 0),
        snaptrade_activity("sale", "SELL", 29, trade_days_ago: 30, units: -10, price: 100, amount: 1000),
        snaptrade_activity("payout", "TRANSFER", 25, amount: -1000)
      ]
    )

    reverse_sync!

    held = [ 31, 30, 29, 28, 0 ].index_with { |days_ago| held_qty(days_ago) }
    assert_equal({ 31 => 0, 30 => 10, 29 => 0, 28 => 0, 0 => 0 }, held)
    assert_equal 1000, balance_on(30)
    assert_no_negative_history
  end

  test "shares moved out are not booked before the buy that delivered them" do
    @snaptrade_account.update!(
      current_balance: 0,
      cash_balance: 0,
      raw_holdings_payload: [],
      raw_activities_payload: [
        snaptrade_activity("deposit", "CONTRIBUTION", 10, amount: 1000),
        snaptrade_activity("buy", "BUY", 4, trade_days_ago: 5, units: 10, price: 100, amount: -1000),
        snaptrade_activity("moved_out", "TRANSFER_OUT", 3, trade_days_ago: 5, units: 10, price: 0)
      ]
    )

    reverse_sync!

    held = [ 5, 4, 3, 0 ].index_with { |days_ago| held_qty(days_ago) }
    assert_equal({ 5 => 0, 4 => 10, 3 => 0, 0 => 0 }, held)
    assert_no_negative_history
  end

  test "shares moved in after the provider priced the position at nothing are not valued at an older price" do
    security = Security.create!(ticker: "RSUCO", name: "RSU Co")
    # An earlier sync's snapshot, once the position had become worthless
    @account.holdings.create!(security: security, date: 20.days.ago.to_date, qty: 100, price: 0, amount: 0, currency: "USD",
                              account_provider: @snaptrade_account.account_provider)

    @snaptrade_account.update!(
      current_balance: 0,
      cash_balance: 0,
      raw_holdings_payload: [ snaptrade_position("RSUCO", 150, 0) ],
      raw_activities_payload: [
        snaptrade_activity("buy", "BUY", 40, units: 100, price: 10, amount: -1000),
        snaptrade_activity("moved_in", "TRANSFER_IN", 10, units: 50, price: 0)
      ]
    )

    reverse_sync!

    assert_equal BigDecimal("150"), held_qty(5)
    assert_equal 0, holdings_value(5), "the provider's zero, not the price paid before it"
  end

  private
    # A SnapTrade activity settling `days_ago`, in the made-up security RSUCO when it has units
    def snaptrade_activity(id, type, days_ago, trade_days_ago: days_ago, units: nil, price: nil, amount: nil, fee: nil)
      {
        "id" => id,
        "type" => type,
        "symbol" => (units ? { "symbol" => "RSUCO", "description" => "RSU Co" } : nil),
        "units" => units,
        "price" => price,
        "amount" => amount,
        "fee" => fee,
        "trade_date" => trade_days_ago.days.ago.to_date.to_s,
        "settlement_date" => days_ago.days.ago.to_date.to_s,
        "currency" => { "code" => "USD" }
      }
    end

    def snaptrade_position(ticker, units, price)
      {
        "symbol" => { "symbol" => { "symbol" => ticker, "description" => "#{ticker} Co" } },
        "units" => units.to_s,
        "price" => price.to_s,
        "currency" => "USD"
      }
    end

    def reverse_sync!
      SnaptradeAccount::Processor.new(@snaptrade_account.reload).process
      Balance::Materializer.new(@account.reload, strategy: :reverse).materialize_balances
    end

    def held_qty(days_ago)
      @account.holdings.where(date: days_ago.days.ago.to_date).sum(:qty)
    end

    def holdings_value(days_ago)
      @account.holdings.where(date: days_ago.days.ago.to_date).sum(:amount)
    end

    def balance_on(days_ago)
      @account.balances.find_by!(date: days_ago.days.ago.to_date).balance
    end

    def assert_no_negative_history
      assert @account.balances.where("balance < 0 OR cash_balance < 0").none?, "no day has a negative balance"
      assert @account.holdings.where("qty < 0").none?, "no day holds negative shares"
    end

    def synced_series
      [
        @account.entries.order(:id).pluck(:id, :amount),
        @account.holdings.order(:date).pluck(:date, :qty, :amount),
        @account.balances.order(:date).pluck(:date, :balance, :cash_balance)
      ]
    end
end
