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

  test "an empty snapshot clears positions the broker stopped reporting" do
    travel_to(Date.new(2026, 12, 18)) { sync_positions!([ stock_position ]) }
    travel_to(Date.new(2026, 12, 28)) { sync_positions!([]) }

    assert_empty current_tickers
  end

  test "a position closed between two syncs on the same day leaves current holdings" do
    sync_positions!([ stock_position, stock_position(securities(:msft).ticker) ])
    sync_positions!([ stock_position, stock_position(securities(:msft).ticker, units: "-5") ]) # now short: no holding

    assert_equal [ securities(:aapl).ticker ], current_tickers
  end

  test "a position that fails to import is not cleared" do
    travel_to(1.day.ago) { sync_positions!([ stock_position ]) }
    SnaptradeAccount::HoldingsProcessor.any_instance.stubs(:process_holding).raises(StandardError)
    sync_positions!([ stock_position ])

    assert_equal [ securities(:aapl).ticker ], current_tickers
  end

  test "a position skipped for a null units or price is not cleared" do
    [ { "price" => nil }, { "units" => nil } ].each do |gap|
      travel_to(1.day.ago) { sync_positions!([ stock_position ]) }
      sync_positions!([ stock_position.merge(gap) ])

      assert_equal [ securities(:aapl).ticker ], current_tickers
    end
  end

  test "an empty snapshot is not trusted while the account total holds non-cash value" do
    travel_to(1.day.ago) { sync_positions!([ stock_position ]) }
    sync_positions!([], total: 2500)

    assert_equal [ securities(:aapl).ticker ], current_tickers
    assert_not @account.holdings.exists?(qty: 0)
  end

  test "an empty snapshot is trusted after 3 days whatever the total" do
    usd_only = [ { "currency" => { "code" => "USD" }, "cash" => 1000 } ]
    # Unlisted futures value, cents of unavailable cash, no total, CAD total vs USD cash
    [ { total: 1000.37 }, { total: 1000.42 }, { total: nil }, { total: 1360, currency: "CAD", raw_balances_payload: usd_only } ].each_with_index do |shape, i|
      travel_to(Date.new(2026, 12, 18) + i.months) { sync_positions!([ stock_position ], **shape) }
      travel_to(Date.new(2026, 12, 21) + i.months) { sync_positions!([], **shape) }
      assert_equal [ securities(:aapl).ticker ], current_tickers, shape.inspect

      travel_to(Date.new(2026, 12, 22) + i.months) { sync_positions!([], **shape) }
      assert_empty current_tickers, shape.inspect
    end
  end

  test "an empty snapshot does not clear positions on an account SnapTrade flags holdings_unavailable" do
    meta = { "sync_status" => { "holdings" => { "holdings_unavailable" => true } } }
    travel_to(Date.new(2026, 12, 18)) { sync_positions!([ stock_position ]) }
    travel_to(Date.new(2026, 12, 28)) { sync_positions!([], institution_metadata: meta) }

    assert_equal [ securities(:aapl).ticker ], current_tickers
  end

  test "a positions list this sync did not fetch does not clear positions" do
    travel_to(Date.new(2026, 12, 18)) { sync_positions!([ stock_position ]) }
    travel_to(Date.new(2026, 12, 28)) { sync_positions!([], last_holdings_sync: 2.hours.ago) }

    assert_equal [ securities(:aapl).ticker ], current_tickers
  end

  test "a row without a symbol that is not cash does not clear the other positions" do
    sync_positions!([ stock_position, stock_position(securities(:msft).ticker) ])
    sync_positions!([ stock_position, { "instrument" => { "kind" => "stock" }, "units" => "5", "price" => "300", "currency" => "USD" } ])

    assert_equal [ securities(:aapl).ticker, securities(:msft).ticker ].sort, current_tickers
  end

  test "a cash row without a symbol still lets sold positions clear" do
    sync_positions!([ stock_position, stock_position(securities(:msft).ticker) ])
    sync_positions!([ stock_position, { "instrument" => { "kind" => "cash", "code" => "USD" }, "units" => "1", "price" => "1", "currency" => "USD" } ])

    assert_equal [ securities(:aapl).ticker ], current_tickers
  end

  test "clearing a sold position leaves another source's row for the same security today" do
    travel_to(1.day.ago) { sync_positions!([ stock_position ]) }
    plaid = AccountProvider.create!(account: @account, provider: plaid_accounts(:one))
    other = @account.holdings.create!(security: securities(:aapl), date: Date.current, currency: "USD", qty: 5, price: 150, amount: 750,
                                      account_provider_id: plaid.id)
    sync_positions!([])

    assert_equal 5, other.reload.qty
  end

  test "an empty list kept against the account total is logged for support" do
    travel_to(1.day.ago) { sync_positions!([ stock_position ]) }

    Rails.logger.stubs(:warn)
    Rails.logger.expects(:warn).with(regexp_matches(/kept positions/)).at_least_once
    sync_positions!([], total: 2500)
    assert_equal [ securities(:aapl).ticker ], current_tickers
  end

  test "a calculated holding without a provider does not stop a sold position from clearing" do
    travel_to(1.day.ago) { sync_positions!([ stock_position ]) }
    sync_positions!([], total: 2500) # kept: the total still reports holdings
    @account.holdings.create!(security: securities(:aapl), date: Date.current, currency: "USD", qty: 10, price: 150, amount: 1500)
    sync_positions!([])

    assert_empty current_tickers
  end

  test "clearing a remapped position does not collide with today's calculated row" do
    travel_to(Date.new(2026, 12, 17)) do
      sync_positions!([ stock_position ])
      @account.holdings.find_by!(security: securities(:aapl)).remap_security!(securities(:msft))
    end
    travel_to(Time.zone.local(2026, 12, 18, 9)) do
      sync_positions!([], total: 2500)
      Holding::Materializer.new(@account.reload, strategy: :reverse).materialize_holdings
    end
    travel_to(Time.zone.local(2026, 12, 18, 15)) do
      assert_nothing_raised { sync_positions!([], total: 1000) }
      assert_empty current_tickers
    end
  end

  test "clearing a position keeps the user's cost-basis lock" do
    travel_to(Date.new(2026, 12, 17)) do
      sync_positions!([ stock_position ])
      @account.holdings.find_by!(security: securities(:aapl)).update!(cost_basis: 42, cost_basis_source: "manual", cost_basis_locked: true)
    end
    travel_to(Time.zone.local(2026, 12, 18, 9)) do
      sync_positions!([], total: 2500)
      Holding::Materializer.new(@account.reload, strategy: :reverse).materialize_holdings
    end
    travel_to(Time.zone.local(2026, 12, 18, 15)) do
      sync_positions!([], total: 1000)
      row = @account.holdings.find_by!(security: securities(:aapl), date: Date.current)
      assert row.cost_basis_locked
      assert_equal 42, row.cost_basis
    end
  end

  test "an empty list from a holdings_unavailable account is not logged" do
    travel_to(Date.new(2026, 12, 17)) { sync_positions!([ stock_position ]) }
    Rails.logger.stubs(:warn)
    Rails.logger.expects(:warn).with(regexp_matches(/kept positions/)).never
    travel_to(Date.new(2026, 12, 18)) do
      sync_positions!([], institution_metadata: { "sync_status" => { "holdings" => { "holdings_unavailable" => true } } })
    end
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

  private

    def sync_positions!(positions, activities = [], total: 1000, **attrs)
      @snaptrade_account.update!(currency: "USD", cash_balance: 1000, current_balance: total, last_holdings_sync: Time.current,
        raw_holdings_payload: positions, raw_activities_payload: activities, **attrs)
      SnaptradeAccount::Processor.new(@snaptrade_account.reload).process
    end

    def current_tickers
      @account.reload.current_holdings.map { |h| h.security.ticker }.sort
    end

    def stock_position(ticker = securities(:aapl).ticker, units: "10")
      { "instrument" => { "kind" => "stock", "symbol" => ticker }, "units" => units, "price" => "150.00", "currency" => "USD" }
    end
end
