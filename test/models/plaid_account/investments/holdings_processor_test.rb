require "test_helper"

class PlaidAccount::Investments::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @plaid_account = plaid_accounts(:one)
    @security_resolver = PlaidAccount::Investments::SecurityResolver.new(@plaid_account)
  end

  test "creates holding records from Plaid holdings snapshot" do
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

    holdings = Holding.where(account: @plaid_account.current_account).order(:date)

    assert_equal 100, holdings.first.qty
    assert_equal 100, holdings.first.price
    assert_equal "USD", holdings.first.currency
    assert_equal securities(:aapl), holdings.first.security
    assert_equal 1.day.ago.to_date, holdings.first.date

    assert_equal 200, holdings.second.qty
    assert_equal 200, holdings.second.price
    assert_equal "USD", holdings.second.currency
    assert_equal securities(:msft), holdings.second.security
    # The undated entry is written on the snapshot's date, not on today
    assert_equal 1.day.ago.to_date, holdings.second.date
  end

  # Users cannot delete Plaid holdings (PlaidAdapter#can_delete_holdings? is
  # false), but a sync retires Plaid's own rows dated after its snapshot: they
  # would stay the newest provider date and hide the snapshot just written.
  test "retires Plaid's own holdings later than the snapshot" do
    account = @plaid_account.current_account

    # Create account_provider
    account_provider = AccountProvider.create!(
      account: account,
      provider: @plaid_account
    )

    # Create a third security for testing
    third_security = Security.create!(ticker: "GOOGL", name: "Google", exchange_operating_mic: "XNAS", country_code: "US")

    # A later AAPL row from an earlier sync whose snapshot was today
    future_aapl_holding = account.holdings.create!(
      security: securities(:aapl),
      date: Date.current,
      qty: 80,
      price: 180,
      amount: 14400,
      currency: "USD",
      account_provider_id: account_provider.id
    )

    # Plaid returns holdings priced one and two days ago, so the snapshot is
    # yesterday's and today's holding is later than it
    test_investments_payload = {
      securities: [],
      holdings: [
        {
          "security_id" => "current",
          "quantity" => 50,
          "institution_price" => 50,
          "iso_currency_code" => "USD",
          "institution_price_as_of" => 1.day.ago.to_date
        },
        {
          "security_id" => "clean",
          "quantity" => 75,
          "institution_price" => 75,
          "iso_currency_code" => "USD",
          "institution_price_as_of" => 2.days.ago.to_date
        },
        {
          "security_id" => "past",
          "quantity" => 100,
          "institution_price" => 100,
          "iso_currency_code" => "USD",
          "institution_price_as_of" => 2.days.ago.to_date
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

    assert_equal 3, account.holdings.count
    assert_not account.holdings.exists?(future_aapl_holding.id)
    assert_equal 1.day.ago.to_date, account.latest_provider_holdings_snapshot_date

    # Should have the correct holdings from Plaid
    assert account.holdings.exists?(security: securities(:msft), date: 1.day.ago.to_date, qty: 50)
    assert account.holdings.exists?(security: third_security, date: 1.day.ago.to_date, qty: 75)
    assert account.holdings.exists?(security: securities(:aapl), date: 1.day.ago.to_date, qty: 100)
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
      date: Date.parse("2025-01-15"),
      currency: "USD"
    )

    assert_not_nil holding, "Expected to find holding for AAPL on 2025-01-15"
    assert_equal BigDecimal("10.5"), holding.qty
    assert_equal BigDecimal("150.75"), holding.price
    assert_equal BigDecimal("1582.875"), holding.amount  # 10.5 * 150.75 using BigDecimal
    assert_equal Date.parse("2025-01-15"), holding.date
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

  # Plaid dates each holding by its own price date. These run the processor on
  # a payload and read the result through the readers of "current holdings",
  # which take the provider rows on the account's single newest date.

  test "holdings priced on different days all land on the snapshot date and are current" do
    snapshot_date = Date.current - 1
    a, b = securities(:aapl), securities(:msft)
    link_account_provider!

    process_holdings(
      "a" => [ a, { "quantity" => 10, "institution_price_as_of" => snapshot_date.to_s } ],
      "b" => [ b, { "quantity" => 5, "institution_price_as_of" => (snapshot_date - 3).to_s } ]
    )

    assert_equal [ a.id, b.id ].sort, account.current_holdings.pluck(:security_id).sort
    assert_equal [ snapshot_date ], account.holdings.distinct.pluck(:date)

    snapshot = Holding::PortfolioSnapshot.new(account)
    assert_equal 5, snapshot.to_h[b.id]
    assert_equal snapshot_date, snapshot.effective_dates[b.id]
  end

  test "a holding reported at zero with a lagging price date lands on the snapshot date and is not current" do
    snapshot_date = Date.current - 1
    a, b = securities(:aapl), securities(:msft)
    link_account_provider!

    process_holdings(
      "a" => [ a, { "quantity" => 10, "institution_price_as_of" => snapshot_date.to_s } ],
      "b" => [ b, { "quantity" => 0, "institution_price_as_of" => (snapshot_date - 3).to_s } ]
    )

    b_holding = account.holdings.find_by!(security: b)
    assert_equal snapshot_date, b_holding.date
    assert_equal 0, b_holding.qty
    assert_equal [ a.id ], account.current_holdings.pluck(:security_id)

    snapshot = Holding::PortfolioSnapshot.new(account)
    assert_equal 0, snapshot.to_h.fetch(b.id)
    assert_equal snapshot_date, snapshot.effective_dates[b.id]
  end

  test "a security sold to zero replaces its earlier quantity on the snapshot date" do
    snapshot_date = Date.current - 1
    a, b = securities(:aapl), securities(:msft)
    account_provider = link_account_provider!
    account.holdings.create!(
      security: b, date: snapshot_date, qty: 10, price: 50, amount: 500,
      currency: "USD", account_provider_id: account_provider.id
    )
    assert_includes account.current_holdings.pluck(:security_id), b.id

    process_holdings(
      "a" => [ a, { "quantity" => 10, "institution_price_as_of" => snapshot_date.to_s } ],
      "b" => [ b, { "quantity" => 0, "institution_price_as_of" => (snapshot_date - 3).to_s } ]
    )

    assert_not_includes account.current_holdings.pluck(:security_id), b.id
    assert_equal 0, account.holdings.find_by!(security: b, date: snapshot_date).qty
  end

  test "a holding priced ahead of today lands on the snapshot date" do
    snapshot_date = Date.current - 1
    a, b = securities(:aapl), securities(:msft)
    link_account_provider!

    process_holdings(
      "a" => [ a, { "quantity" => 10, "institution_price_as_of" => snapshot_date.to_s } ],
      "b" => [ b, { "quantity" => 5, "institution_price_as_of" => (Date.current + 1).to_s } ]
    )

    assert_equal [ a.id, b.id ].sort, account.current_holdings.pluck(:security_id).sort
    assert_equal [ snapshot_date ], account.holdings.distinct.pluck(:date)
    assert_equal snapshot_date, account.latest_provider_holdings_snapshot_date
  end

  test "an undated holding takes the snapshot date, not today" do
    snapshot_date = Date.current - 1
    a, b = securities(:aapl), securities(:msft)
    link_account_provider!

    process_holdings(
      "a" => [ a, { "quantity" => 10, "institution_price_as_of" => snapshot_date.to_s } ],
      "b" => [ b, { "quantity" => 5 } ]
    )

    assert_equal [ a.id, b.id ].sort, account.current_holdings.pluck(:security_id).sort
    assert_equal [ snapshot_date ], account.holdings.distinct.pluck(:date)
  end

  test "a security from an earlier snapshot is not current and its row is kept" do
    snapshot_date = Date.current - 1
    a, b = securities(:aapl), securities(:msft)
    c = Security.create!(ticker: "GOOGL", name: "Google", exchange_operating_mic: "XNAS", country_code: "US")
    account_provider = link_account_provider!
    earlier = account.holdings.create!(
      security: c, date: snapshot_date - 1, qty: 3, price: 50, amount: 150,
      currency: "USD", account_provider_id: account_provider.id
    )

    process_holdings(
      "a" => [ a, { "quantity" => 10, "institution_price_as_of" => snapshot_date.to_s } ],
      "b" => [ b, { "quantity" => 5, "institution_price_as_of" => (snapshot_date - 3).to_s } ]
    )

    assert_not_includes account.current_holdings.pluck(:security_id), c.id
    assert_equal 3, earlier.reload.qty
    assert_equal snapshot_date - 1, earlier.date
  end

  test "a payload priced on one day is written on that day" do
    price_date = Date.current - 4
    link_account_provider!

    process_holdings(
      "a" => [ securities(:aapl), { "quantity" => 10, "institution_price_as_of" => price_date.to_s } ],
      "b" => [ securities(:msft), { "quantity" => 5, "institution_price_as_of" => price_date.to_s } ]
    )

    assert_equal [ price_date, price_date ], account.holdings.pluck(:date)
  end

  test "with no usable price date, holdings land on today" do
    c = Security.create!(ticker: "GOOGL", name: "Google", exchange_operating_mic: "XNAS", country_code: "US")
    link_account_provider!

    process_holdings(
      "a" => [ securities(:aapl), { "quantity" => 10 } ],
      "b" => [ securities(:msft), { "quantity" => 5, "institution_price_as_of" => "not a date" } ],
      "c" => [ c, { "quantity" => 3, "institution_price_as_of" => (Date.current + 1).to_s } ]
    )

    assert_equal [ Date.current ] * 3, account.holdings.pluck(:date)
  end

  # A malformed price date is dropped from the snapshot date silently, and with
  # nothing else usable the whole sync lands on today. Support needs to see why.
  test "an unparseable price date is recorded once per sync for support" do
    account_provider = link_account_provider!

    assert_difference -> { DebugLogEntry.where(category: "provider_sync", provider_key: "plaid").count }, 1 do
      process_holdings(
        "a" => [ securities(:aapl), { "quantity" => 10, "institution_price_as_of" => "not a date" } ],
        "b" => [ securities(:msft), { "quantity" => 5, "institution_price_as_of" => "31/02/2026" } ]
      )
    end

    entry = DebugLogEntry.where(provider_key: "plaid").order(:created_at).last
    assert_equal "warn", entry.level
    assert_equal account_provider, entry.account_provider
    assert_equal account.family, entry.family
    assert_equal [ "not a date", "31/02/2026" ], entry.metadata["unparseable_dates"]
    assert_equal Date.current.iso8601, entry.metadata["snapshot_date"]
  end

  test "missing, blank and future price dates record nothing" do
    link_account_provider!

    assert_no_difference -> { DebugLogEntry.where(provider_key: "plaid").count } do
      process_holdings(
        "a" => [ securities(:aapl), { "quantity" => 10 } ],
        "b" => [ securities(:msft), { "quantity" => 5, "institution_price_as_of" => "" } ],
        "c" => [ Security.create!(ticker: "GOOGL", name: "Google", exchange_operating_mic: "XNAS", country_code: "US"),
                 { "quantity" => 3, "institution_price_as_of" => (Date.current + 1).to_s } ]
      )
    end
  end

  # A sync can be dated before the last one: one with no usable price date
  # lands on today, and the next, dated, sync goes on its newest price date.
  test "a snapshot dated before the last sync becomes the current one" do
    snapshot_date = Date.current - 1
    a, b = securities(:aapl), securities(:msft)
    link_account_provider!

    process_holdings("a" => [ a, { "quantity" => 10 } ], "b" => [ b, { "quantity" => 5 } ])
    assert_equal Date.current, account.latest_provider_holdings_snapshot_date

    process_holdings(
      "a" => [ a, { "quantity" => 12, "institution_price_as_of" => snapshot_date.to_s } ],
      "b" => [ b, { "quantity" => 7, "institution_price_as_of" => snapshot_date.to_s } ]
    )

    assert_equal snapshot_date, account.latest_provider_holdings_snapshot_date
    assert_equal({ a.id => 12, b.id => 7 }, account.current_holdings.to_h { |holding| [ holding.security_id, holding.qty.to_i ] })
  end

  test "later rows of another provider or with no provider are kept" do
    snapshot_date = Date.current - 1
    link_account_provider!
    item = SimplefinItem.create!(family: account.family, name: "SF", access_url: "https://example.com/access")
    simplefin_account = SimplefinAccount.create!(simplefin_item: item, name: "Broker", account_id: "sf_1",
                                                 currency: "USD", account_type: "investment", current_balance: 0)
    other_provider = AccountProvider.create!(account: account, provider: simplefin_account)
    google = Security.create!(ticker: "GOOGL", name: "Google", exchange_operating_mic: "XNAS", country_code: "US")
    other = account.holdings.create!(security: google, date: Date.current, qty: 3, price: 50, amount: 150,
                                     currency: "USD", account_provider_id: other_provider.id)
    calculated = account.holdings.create!(security: google, date: Date.current + 1, qty: 3, price: 50, amount: 150, currency: "USD")

    process_holdings("a" => [ securities(:aapl), { "quantity" => 10, "institution_price_as_of" => snapshot_date.to_s } ])

    assert account.holdings.exists?(other.id)
    assert account.holdings.exists?(calculated.id)
  end

  # Without an account provider the rows are written with none, like
  # calculated rows; nothing later may be removed by matching a nil provider.
  test "with no account provider no later row is removed" do
    google = Security.create!(ticker: "GOOGL", name: "Google", exchange_operating_mic: "XNAS", country_code: "US")
    calculated = account.holdings.create!(security: google, date: Date.current, qty: 3, price: 50, amount: 150, currency: "USD")

    process_holdings("a" => [ securities(:aapl), { "quantity" => 10, "institution_price_as_of" => (Date.current - 1).to_s } ])

    assert account.holdings.exists?(calculated.id)
  end

  private
    def account
      @plaid_account.current_account
    end

    def link_account_provider!
      AccountProvider.create!(account: account, provider: @plaid_account).tap { @plaid_account.reload }
    end

    # entries: { plaid_security_id => [security, holding attributes] }
    def process_holdings(entries)
      holdings = entries.map do |plaid_security_id, (security, attributes)|
        @security_resolver.stubs(:resolve)
                          .with(plaid_security_id: plaid_security_id)
                          .returns(OpenStruct.new(security: security))

        { "security_id" => plaid_security_id, "institution_price" => 50, "iso_currency_code" => "USD" }.merge(attributes)
      end

      @plaid_account.update!(raw_holdings_payload: { "holdings" => holdings })
      PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver).process
    end
end
