require "test_helper"

class PlaidAccount::Investments::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @plaid_account = plaid_accounts(:one)
    @security_resolver = PlaidAccount::Investments::SecurityResolver.new(@plaid_account)
  end

  test "creates holding records from Plaid holdings snapshot, dated by the sync day" do
    test_investments_payload = {
      securities: [], # mocked
      holdings: [
        {
          "security_id" => "123",
          "quantity" => 100,
          "institution_price" => 100,
          "iso_currency_code" => "USD",
          "institution_price_as_of" => 1.day.ago.to_date
        },
        {
          "security_id" => "456",
          "quantity" => 200,
          "institution_price" => 200,
          "iso_currency_code" => "USD"
        }
      ],
      transactions: [] # not relevant for test
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "123")
                      .returns(
                        OpenStruct.new(
                          security: securities(:aapl),
                          cash_equivalent?: false,
                          brokerage_cash?: false
                        )
                      )

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "456")
                      .returns(
                        OpenStruct.new(
                          security: securities(:msft),
                          cash_equivalent?: false,
                          brokerage_cash?: false
                        )
                      )

    processor = PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    assert_difference "Holding.count", 2 do
      processor.process
    end

    holdings = Holding.where(account: @plaid_account.current_account)
    aapl = holdings.find_by!(security: securities(:aapl))
    msft = holdings.find_by!(security: securities(:msft))

    assert_equal 100, aapl.qty
    assert_equal 100, aapl.price, "the price Plaid reports, as of its price date"
    assert_equal "USD", aapl.currency
    assert_equal Date.current, aapl.date, "dated by the sync, not by institution_price_as_of"

    assert_equal 200, msft.qty
    assert_equal 200, msft.price
    assert_equal "USD", msft.currency
    assert_equal Date.current, msft.date
  end

  test "uses the supplied snapshot currency when a holding omits its own currency" do
    account = @plaid_account.current_account
    account.update!(currency: "USD")
    holding_date = 5.days.ago.to_date
    @plaid_account.update!(
      currency: "EUR",
      raw_holdings_payload: {
        securities: [],
        holdings: [
          {
            "security_id" => "123",
            "quantity" => 1,
            "institution_price" => 10,
            "institution_price_as_of" => holding_date
          }
        ],
        transactions: []
      }
    )

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "123")
                      .returns(
                        OpenStruct.new(
                          security: securities(:aapl),
                          cash_equivalent?: false,
                          brokerage_cash?: false
                        )
                      )

    processor = PlaidAccount::Investments::HoldingsProcessor.new(
      @plaid_account,
      security_resolver: @security_resolver,
      currency: @plaid_account.currency
    )
    processor.process

    holding = Holding.find_by!(account: account, security: securities(:aapl), date: Date.current)
    assert_equal "EUR", holding.currency
  end

  # Plaid does not delete future holdings because it doesn't support holdings deletion
  # (PlaidAdapter#can_delete_holdings? returns false). This test verifies that future
  # holdings are NOT deleted when processing Plaid holdings data.
  test "does not delete future holdings when processing Plaid holdings" do
    account = @plaid_account.current_account

    # Create account_provider
    account_provider = AccountProvider.create!(
      account: account,
      provider: @plaid_account
    )

    # Create a third security for testing
    third_security = Security.create!(ticker: "GOOGL", name: "Google", exchange_operating_mic: "XNAS", country_code: "US")

    # Create a future AAPL holding that should NOT be deleted
    future_aapl_holding = account.holdings.create!(
      security: securities(:aapl),
      date: 1.day.from_now.to_date,
      qty: 80,
      price: 180,
      amount: 14400,
      currency: "USD",
      account_provider_id: account_provider.id
    )

    # Plaid returns some holdings priced yesterday - future holdings should remain
    test_investments_payload = {
      securities: [],
      holdings: [
        {
          "security_id" => "current",
          "quantity" => 50,
          "institution_price" => 50,
          "iso_currency_code" => "USD",
          "institution_price_as_of" => Date.current
        },
        {
          "security_id" => "clean",
          "quantity" => 75,
          "institution_price" => 75,
          "iso_currency_code" => "USD",
          "institution_price_as_of" => 1.day.ago.to_date
        },
        {
          "security_id" => "past",
          "quantity" => 100,
          "institution_price" => 100,
          "iso_currency_code" => "USD",
          "institution_price_as_of" => 1.day.ago.to_date
        }
      ],
      transactions: []
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    # Mock security resolver for all three securities
    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "current")
                      .returns(OpenStruct.new(security: securities(:msft), cash_equivalent?: false, brokerage_cash?: false))

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "clean")
                      .returns(OpenStruct.new(security: third_security, cash_equivalent?: false, brokerage_cash?: false))

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "past")
                      .returns(OpenStruct.new(security: securities(:aapl), cash_equivalent?: false, brokerage_cash?: false))

    processor = PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver)
    processor.process

    # Should have created 3 new holdings PLUS the existing future holding (total 4)
    assert_equal 4, account.holdings.count

    # Future AAPL holding should still exist (NOT deleted)
    assert account.holdings.exists?(future_aapl_holding.id)

    # Should have the correct holdings from Plaid
    assert account.holdings.exists?(security: securities(:msft), date: Date.current, qty: 50)
    assert account.holdings.exists?(security: third_security, date: Date.current, qty: 75)
    assert account.holdings.exists?(security: securities(:aapl), date: Date.current, qty: 100)
  end

  test "continues processing other holdings when security resolution fails" do
    test_investments_payload = {
      securities: [],
      holdings: [
        {
          "security_id" => "fail",
          "quantity" => 100,
          "institution_price" => 100,
          "iso_currency_code" => "USD"
        },
        {
          "security_id" => "success",
          "quantity" => 200,
          "institution_price" => 200,
          "iso_currency_code" => "USD"
        }
      ],
      transactions: []
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    # First security fails to resolve
    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "fail")
                      .returns(OpenStruct.new(security: nil))

    # Second security succeeds
    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "success")
                      .returns(OpenStruct.new(security: securities(:aapl)))

    processor = PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    # Should create only 1 holding (the successful one)
    assert_difference "Holding.count", 1 do
      processor.process
    end

    # Should have created the successful holding
    assert @plaid_account.current_account.holdings.exists?(security: securities(:aapl), qty: 200)
  end

  test "handles string values and computes amount using BigDecimal arithmetic" do
    test_investments_payload = {
      securities: [],
      holdings: [
        {
          "security_id" => "string_values",
          "quantity" => "10.5",
          "institution_price" => "150.75",
          "iso_currency_code" => "USD",
          "institution_price_as_of" => "2025-01-15"
        }
      ],
      transactions: []
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "string_values")
                      .returns(OpenStruct.new(security: securities(:aapl)))

    processor = PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    assert_difference "Holding.count", 1 do
      processor.process
    end

    holding = @plaid_account.current_account.holdings.find_by(
      security: securities(:aapl),
      date: Date.current,
      currency: "USD"
    )

    assert_not_nil holding, "Expected to find holding for AAPL dated by the sync day"
    assert_equal BigDecimal("10.5"), holding.qty
    assert_equal BigDecimal("150.75"), holding.price
    assert_equal BigDecimal("1582.875"), holding.amount  # 10.5 * 150.75 using BigDecimal
    assert_equal Date.current, holding.date
  end

  test "skips holdings with nil quantity or price" do
    test_investments_payload = {
      securities: [],
      holdings: [
        {
          "security_id" => "missing_quantity",
          "quantity" => nil,
          "institution_price" => 100,
          "iso_currency_code" => "USD"
        },
        {
          "security_id" => "missing_price",
          "quantity" => 100,
          "institution_price" => nil,
          "iso_currency_code" => "USD"
        },
        {
          "security_id" => "valid",
          "quantity" => 50,
          "institution_price" => 50,
          "iso_currency_code" => "USD"
        }
      ],
      transactions: []
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "missing_quantity")
                      .returns(OpenStruct.new(security: securities(:aapl)))

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "missing_price")
                      .returns(OpenStruct.new(security: securities(:msft)))

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "valid")
                      .returns(OpenStruct.new(security: securities(:aapl)))

    processor = PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    # Should create only 1 holding (the valid one)
    assert_difference "Holding.count", 1 do
      processor.process
    end

    # Should have created only the valid holding
    assert @plaid_account.current_account.holdings.exists?(security: securities(:aapl), qty: 50, price: 50)
    assert_not @plaid_account.current_account.holdings.exists?(security: securities(:msft))
  end

  test "uses account currency as fallback when Plaid omits iso_currency_code" do
    account = @plaid_account.current_account

    # Ensure the account has a currency
    account.update!(currency: "EUR")

    test_investments_payload = {
      securities: [],
      holdings: [
        {
          "security_id" => "no_currency",
          "quantity" => 100,
          "institution_price" => 100,
          "iso_currency_code" => nil,  # Plaid omits currency
          "institution_price_as_of" => Date.current
        }
      ],
      transactions: []
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "no_currency")
                      .returns(OpenStruct.new(security: securities(:aapl)))

    processor = PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    assert_difference "Holding.count", 1 do
      processor.process
    end

    holding = account.holdings.find_by(security: securities(:aapl))
    assert_equal "EUR", holding.currency  # Should use account's currency
  end

  test "sums Plaid holdings that resolve to the same security into one row" do
    @plaid_account.update!(raw_holdings_payload: { "holdings" => [
      { "security_id" => "aapl_a", "quantity" => 10, "institution_price" => 100, "iso_currency_code" => "USD" },
      { "security_id" => "aapl_b", "quantity" => 5, "institution_price" => 110, "iso_currency_code" => "USD" }
    ] })
    @security_resolver.stubs(:resolve).returns(OpenStruct.new(security: securities(:aapl), cash_equivalent?: false, brokerage_cash?: false))

    assert_difference "Holding.count", 1 do
      PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver).process
    end

    holding = @plaid_account.current_account.holdings.find_by!(security: securities(:aapl), date: Date.current)
    assert_equal 15, holding.qty
    assert_equal 1550, holding.amount
    assert_in_delta 103.3333, holding.price, 0.001
  end

  test "holdings of one security that net to zero are stored with no value" do
    @plaid_account.update!(raw_holdings_payload: { "holdings" => [
      { "security_id" => "aapl_long", "quantity" => 10, "institution_price" => 110, "iso_currency_code" => "USD" },
      { "security_id" => "aapl_short", "quantity" => -10, "institution_price" => 100, "iso_currency_code" => "USD" }
    ] })
    @security_resolver.stubs(:resolve).returns(OpenStruct.new(security: securities(:aapl), cash_equivalent?: false, brokerage_cash?: false))

    PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver).process

    holding = @plaid_account.current_account.holdings.find_by!(security: securities(:aapl), date: Date.current)
    assert_equal 0, holding.qty
    assert_equal 0, holding.amount
  end

  test "a short priced above the long nets to zero without stopping the rest of the snapshot" do
    @plaid_account.update!(raw_holdings_payload: { "holdings" => [
      { "security_id" => "aapl_long", "quantity" => 10, "institution_price" => 100, "iso_currency_code" => "USD" },
      { "security_id" => "aapl_short", "quantity" => -10, "institution_price" => 110, "iso_currency_code" => "USD" },
      { "security_id" => "msft", "quantity" => 1, "institution_price" => 50, "iso_currency_code" => "USD" }
    ] })
    aapl = OpenStruct.new(security: securities(:aapl), cash_equivalent?: false, brokerage_cash?: false)
    @security_resolver.stubs(:resolve).with(plaid_security_id: "aapl_long").returns(aapl)
    @security_resolver.stubs(:resolve).with(plaid_security_id: "aapl_short").returns(aapl)
    @security_resolver.stubs(:resolve).with(plaid_security_id: "msft")
      .returns(OpenStruct.new(security: securities(:msft), cash_equivalent?: false, brokerage_cash?: false))

    PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver).process

    holdings = @plaid_account.current_account.holdings.where(date: Date.current)
    aapl_row = holdings.find_by!(security: securities(:aapl))
    assert_equal 0, aapl_row.qty
    assert_equal 0, aapl_row.amount
    assert_equal 1, holdings.find_by!(security: securities(:msft)).qty, "the holdings after it are still imported"
  end

  test "a short priced above the long that leaves shares held values them at the long's price" do
    @plaid_account.update!(raw_holdings_payload: { "holdings" => [
      { "security_id" => "aapl_short", "quantity" => -5, "institution_price" => 200, "iso_currency_code" => "USD" },
      { "security_id" => "aapl_long", "quantity" => 10, "institution_price" => 50, "iso_currency_code" => "USD" },
      { "security_id" => "msft", "quantity" => 1, "institution_price" => 50, "iso_currency_code" => "USD" }
    ] })
    aapl = OpenStruct.new(security: securities(:aapl), cash_equivalent?: false, brokerage_cash?: false)
    @security_resolver.stubs(:resolve).with(plaid_security_id: "aapl_long").returns(aapl)
    @security_resolver.stubs(:resolve).with(plaid_security_id: "aapl_short").returns(aapl)
    @security_resolver.stubs(:resolve).with(plaid_security_id: "msft")
      .returns(OpenStruct.new(security: securities(:msft), cash_equivalent?: false, brokerage_cash?: false))

    PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver).process

    holdings = @plaid_account.current_account.holdings.where(date: Date.current)
    aapl_row = holdings.find_by!(security: securities(:aapl))
    assert_equal 5, aapl_row.qty
    assert_equal 50, aapl_row.price
    assert_equal 250, aapl_row.amount
    assert_equal 1, holdings.find_by!(security: securities(:msft)).qty, "the holdings after it are still imported"
  end

  test "a net short is left out without stopping the rest of the snapshot" do
    @plaid_account.update!(raw_holdings_payload: { "holdings" => [
      { "security_id" => "aapl_long", "quantity" => 5, "institution_price" => 100, "iso_currency_code" => "USD" },
      { "security_id" => "aapl_short", "quantity" => -10, "institution_price" => 100, "iso_currency_code" => "USD" },
      { "security_id" => "msft", "quantity" => 1, "institution_price" => 50, "iso_currency_code" => "USD" }
    ] })
    aapl = OpenStruct.new(security: securities(:aapl), cash_equivalent?: false, brokerage_cash?: false)
    @security_resolver.stubs(:resolve).with(plaid_security_id: "aapl_long").returns(aapl)
    @security_resolver.stubs(:resolve).with(plaid_security_id: "aapl_short").returns(aapl)
    @security_resolver.stubs(:resolve).with(plaid_security_id: "msft")
      .returns(OpenStruct.new(security: securities(:msft), cash_equivalent?: false, brokerage_cash?: false))

    PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver).process

    holdings = @plaid_account.current_account.holdings.where(date: Date.current)
    assert_not holdings.exists?(security: securities(:aapl))
    assert_equal 1, holdings.find_by!(security: securities(:msft)).qty, "the holdings after it are still imported"
  end

  test "a position that turns net short on a later sync the same day closes the long row" do
    aapl = OpenStruct.new(security: securities(:aapl), cash_equivalent?: false, brokerage_cash?: false)
    @security_resolver.stubs(:resolve).returns(aapl)
    @plaid_account.update!(raw_holdings_payload: { "holdings" => [
      { "security_id" => "aapl_long", "quantity" => 5, "institution_price" => 100, "iso_currency_code" => "USD" }
    ] })
    PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver).process
    assert_equal 5, @plaid_account.current_account.holdings.find_by!(security: securities(:aapl), date: Date.current).qty

    @plaid_account.update!(raw_holdings_payload: { "holdings" => [
      { "security_id" => "aapl_long", "quantity" => 5, "institution_price" => 100, "iso_currency_code" => "USD" },
      { "security_id" => "aapl_short", "quantity" => -10, "institution_price" => 100, "iso_currency_code" => "USD" }
    ] })
    assert_no_difference "Holding.count" do
      PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver).process
    end

    holding = @plaid_account.current_account.holdings.find_by!(security: securities(:aapl), date: Date.current)
    assert_equal 0, holding.qty
    assert_equal 0, holding.amount
  end

  test "a position that turns net short the same day closes a long row the user remapped" do
    @security_resolver.stubs(:resolve).returns(OpenStruct.new(security: securities(:aapl), cash_equivalent?: false, brokerage_cash?: false))
    @plaid_account.update!(raw_holdings_payload: { "holdings" => [
      { "security_id" => "aapl_long", "quantity" => 5, "institution_price" => 100, "iso_currency_code" => "USD" }
    ] })
    PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver).process
    row = @plaid_account.current_account.holdings.find_by!(security: securities(:aapl), date: Date.current)
    row.remap_security!(securities(:msft))

    @plaid_account.update!(raw_holdings_payload: { "holdings" => [
      { "security_id" => "aapl_long", "quantity" => 5, "institution_price" => 100, "iso_currency_code" => "USD" },
      { "security_id" => "aapl_short", "quantity" => -10, "institution_price" => 100, "iso_currency_code" => "USD" }
    ] })
    assert_no_difference "Holding.count" do
      PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver).process
    end

    row.reload
    assert_equal securities(:msft), row.security
    assert_equal 0, row.qty
    assert_equal 0, row.amount
  end

  test "dates every holding by the sync date it is given" do
    @plaid_account.update!(raw_holdings_payload: { "holdings" => [
      { "security_id" => "aapl", "quantity" => 10, "institution_price" => 100, "iso_currency_code" => "USD" }
    ] })
    @security_resolver.stubs(:resolve).returns(OpenStruct.new(security: securities(:aapl), cash_equivalent?: false, brokerage_cash?: false))

    sync_date = Date.current - 1
    PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver, as_of: sync_date).process

    assert_equal [ sync_date ], @plaid_account.current_account.holdings.where(security: securities(:aapl)).pluck(:date)
  end

  # A mutual fund's NAV is a session behind, so Plaid prices it as of
  # yesterday on every sync while the stocks are priced today. Both are held,
  # so the holdings page, the dashboard and the assistant all list both.
  test "a fund priced a session behind stays in the account's current holdings" do
    account, plaid_account = linked_plaid_brokerage
    plaid_sync!(plaid_account, Date.new(2026, 12, 17), "AAPL" => [ Date.new(2026, 12, 17), 100 ], "MSFT" => [ Date.new(2026, 12, 16), 50 ])
    plaid_sync!(plaid_account, Date.new(2026, 12, 18), "AAPL" => [ Date.new(2026, 12, 18), 101 ], "MSFT" => [ Date.new(2026, 12, 17), 51 ])

    travel_to(Time.utc(2026, 12, 18, 18)) do
      assert_current_tickers account, %w[AAPL MSFT]
      assert_equal 51, account.current_holdings.find { |h| h.security.ticker == "MSFT" }.price, "the fund keeps Plaid's NAV"
    end
  end

  # A Saturday sync re-imports AAPL with Friday's price unchanged, while the
  # fund gets its Friday NAV. AAPL must not drop out of the latest snapshot
  # because its price and price date did not change.
  test "a holding re-imported unchanged on a later day stays current" do
    account, plaid_account = linked_plaid_brokerage
    plaid_sync!(plaid_account, Date.new(2026, 12, 18), "AAPL" => [ Date.new(2026, 12, 18), 101 ], "MSFT" => [ Date.new(2026, 12, 17), 51 ])
    plaid_sync!(plaid_account, Date.new(2026, 12, 19), "AAPL" => [ Date.new(2026, 12, 18), 101 ], "MSFT" => [ Date.new(2026, 12, 18), 52 ])

    travel_to(Time.utc(2026, 12, 19, 18)) do
      assert_current_tickers account, %w[AAPL MSFT]
    end
  end

  private
    def linked_plaid_brokerage
      family = families(:dylan_family)
      family.update!(timezone: "UTC")
      account = family.accounts.create!(name: "Plaid brokerage", balance: 0, currency: "USD", accountable: Investment.new, owner: users(:family_admin))
      plaid_account = PlaidAccount.create!(plaid_item: plaid_items(:one), plaid_id: "inv_lagging_nav", name: "Brokerage",
        plaid_type: "investment", plaid_subtype: "brokerage", currency: "USD", current_balance: 0)
      AccountProvider.create!(account: account, provider: plaid_account)
      [ account, plaid_account ]
    end

    # The holdings page, the dashboard (InvestmentStatement) and the assistant.
    def assert_current_tickers(account, expected)
      account.reload
      assert_equal expected, account.current_holdings.map { |h| h.security.ticker }.sort, "holdings page"

      statement = InvestmentStatement.new(account.family, user: nil)
      assert_equal expected, statement.current_holdings.select { |h| h.account_id == account.id }.map { |h| h.security.ticker }.sort, "dashboard"
      assert_empty expected - statement.top_holdings(limit: 50).map(&:ticker), "top holdings"

      rows = Assistant::Function::GetHoldings.new(users(:family_admin)).call("page" => 1, "accounts" => [ account.name ])[:holdings]
      assert_equal expected, rows.map { |row| row[:ticker] }.sort, "get_holdings"
    end

    # holdings: { ticker => [institution_price_as_of, price] }, synced at noon
    # UTC on `day` in the family's zone, the way Sync#perform runs it.
    def plaid_sync!(plaid_account, day, holdings)
      securities = { "AAPL" => securities(:aapl), "MSFT" => securities(:msft) }
      travel_to(day.in_time_zone("UTC").change(hour: 12)) do
        Time.use_zone(plaid_account.plaid_item.family.resolved_time_zone) do
          payload = holdings.map do |ticker, (as_of, price)|
            { "security_id" => ticker, "quantity" => 10, "institution_price" => price,
              "iso_currency_code" => "USD", "institution_price_as_of" => as_of.to_s }
          end
          plaid_account.update!(raw_holdings_payload: { "holdings" => payload })
          resolver = PlaidAccount::Investments::SecurityResolver.new(plaid_account)
          holdings.each_key do |ticker|
            resolver.stubs(:resolve).with(plaid_security_id: ticker)
              .returns(OpenStruct.new(security: securities[ticker], cash_equivalent?: false, brokerage_cash?: false))
          end
          PlaidAccount::Investments::HoldingsProcessor.new(plaid_account.reload, security_resolver: resolver).process
        end
      end
    end
end
