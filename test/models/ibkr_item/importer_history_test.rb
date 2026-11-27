require "test_helper"

class IbkrItem::ImporterHistoryTest < ActiveSupport::TestCase
  fixtures :families, :ibkr_items, :ibkr_accounts, :securities

  # Stands in for Provider::IbkrFlex: answers per requested range and records
  # every call. nil/nil is the query's own period.
  class FakeFlex
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def download_statement(from_date: nil, to_date: nil)
      @calls << [ from_date, to_date ]
      response = @responses.fetch([ from_date, to_date ])
      response = response.call if response.respond_to?(:call)
      raise response if response.is_a?(Exception)

      response
    end
  end

  CURRENT = [ nil, nil ].freeze
  WINDOW_1 = [ Date.new(2024, 5, 8), Date.new(2025, 5, 7) ].freeze
  WINDOW_2 = [ Date.new(2023, 5, 9), Date.new(2024, 5, 7) ].freeze
  WINDOW_3 = [ Date.new(2022, 5, 9), Date.new(2023, 5, 8) ].freeze
  WINDOW_4 = [ Date.new(2022, 1, 1), Date.new(2022, 5, 8) ].freeze # IBKR keeps the four previous calendar years

  setup do
    travel_to Time.zone.local(2026, 5, 9, 10)
    @ibkr_item = ibkr_items(:configured_item)
    @ibkr_account = ibkr_accounts(:main_account)
    @account = new_account
    @ibkr_account.ensure_account_provider!(@account)
    @current = file_fixture("ibkr/flex_statement.xml").read # fromDate 2025-05-08
    Security.any_instance.stubs(:import_provider_prices)
  end

  # A quiet year (no trades, cash or NAV rows) does not end the walk.
  test "imports each older window as it is fetched, back to the oldest year IBKR keeps" do
    provider = history_provider

    import(provider)

    assert_equal [ CURRENT, WINDOW_1, WINDOW_2, WINDOW_3, WINDOW_4 ], provider.calls
    assert @account.entries.exists?(external_id: "ibkr_trade_901", source: "ibkr")
    # The stored payload and balance stay the current statement's.
    @ibkr_account.reload
    assert_equal %w[1001 1002], @ibkr_account.raw_activities_payload["trades"].map { |row| row["trade_id"] }
    assert_equal BigDecimal("3351.0"), @ibkr_account.current_balance

    # Once complete, a sync is a single request again.
    import(provider)
    assert_equal [ CURRENT, WINDOW_1, WINDOW_2, WINDOW_3, WINDOW_4, CURRENT ], provider.calls
  end

  test "a statement for another range than the one asked ends the walk" do
    provider = FakeFlex.new(CURRENT => @current, WINDOW_1 => @current)

    2.times { import(provider) }

    assert_equal [ CURRENT, WINDOW_1, CURRENT ], provider.calls
  end

  test "backfilled history older than the default opening anchor moves the anchor before it" do
    @ibkr_account.account_provider.destroy!
    account = Account.create_from_ibkr_account(@ibkr_account.reload)
    @ibkr_account.ensure_account_provider!(account)
    assert_equal Date.new(2024, 5, 9), account.reload.opening_anchor_date

    deposit = %(<CashTransaction transactionID="7001" type="Deposits/Withdrawals" amount="10000.00" currency="CHF" fxRateToBase="1" reportDate="2023-06-01" />)
    provider = FakeFlex.new(CURRENT => window_xml(Date.new(2025, 5, 8), Date.new(2026, 5, 8), nav_date: "2026-05-08", total: "10000.00", cash: "10000.00"),
                            WINDOW_1 => window_xml(*WINDOW_1), WINDOW_2 => window_xml(*WINDOW_2, cash_transaction: deposit),
                            WINDOW_3 => window_xml(*WINDOW_3), WINDOW_4 => window_xml(*WINDOW_4))
    import(provider)
    @ibkr_item.reload.process_accounts

    account = Account.find(account.id)
    Balance::Materializer.new(account, strategy: :reverse).materialize_balances
    balances = account.balances.where(currency: "CHF").index_by(&:date)
    assert_in_delta 10000, balances[Date.new(2024, 1, 1)].balance, 0.01, "after the 2023-06-01 deposit the account held 10k"
    assert_in_delta 0, balances[Date.new(2023, 6, 1)].start_balance, 0.01, "the day of the deposit starts from zero"
  end

  # Progress is recorded only once the window's rows are imported, not when it is fetched.
  test "a window is imported in the sync that fetched it, even if that sync stops before processing" do
    import(history_provider)
    import(FakeFlex.new(CURRENT => @current))
    @ibkr_item.process_accounts

    assert @account.entries.exists?(external_id: "ibkr_trade_901")
  end

  test "a failing window never fails the sync, is retried, and is given up only after repeated permanent errors" do
    provider = FakeFlex.new(CURRENT => @current, WINDOW_1 => window_xml(*WINDOW_1, trade_id: "901", nav_date: "2024-06-03"),
                            WINDOW_2 => OpenSSL::SSL::SSLError.new("SSL_read: unexpected eof"))

    assert_equal true, import(provider)[:success]
    assert @account.entries.exists?(external_id: "ibkr_trade_901"), "the window before the failure is kept"
    assert DebugLogEntry.where(source: "IbkrItem::Importer", provider_key: "ibkr").exists?

    # Busy, "try again shortly", unknown or code-less (HTML page) errors only stop this sync, however often.
    [ "1019", "1021", "1005", "1018", "9999", nil ].each do |code|
      error = Provider::IbkrFlex::ApiError.new("Please try again shortly.", error_code: code)
      IbkrItem::Importer::MAX_HISTORY_FAILURES.times { import(FakeFlex.new(CURRENT => @current, WINDOW_2 => error)) }
    end

    unavailable = Provider::IbkrFlex::ApiError.new("Statement is not available.", error_code: "1003")
    provider = FakeFlex.new(CURRENT => @current, WINDOW_2 => unavailable)
    (IbkrItem::Importer::MAX_HISTORY_FAILURES + 1).times { import(provider) }

    assert_equal [ CURRENT, WINDOW_2 ] * IbkrItem::Importer::MAX_HISTORY_FAILURES + [ CURRENT ], provider.calls
  end

  test "a window IBKR answers without statements is given up eventually" do
    empty = "<FlexQueryResponse queryName=\"Sure Test\" type=\"AF\"><FlexStatements count=\"0\" /></FlexQueryResponse>"
    provider = FakeFlex.new(CURRENT => @current, WINDOW_1 => empty)

    6.times { import(provider) }

    assert_operator provider.calls.count(WINDOW_1), :<=, IbkrItem::Importer::MAX_HISTORY_FAILURES,
      "WINDOW_1 requested #{provider.calls.count(WINDOW_1)} times in 6 syncs"
  end

  test "a cut-off statement is retried, never counted as one IBKR has no statements for" do
    truncated = window_xml(*WINDOW_1, trade_id: "901", nav_date: "2024-06-03")[0, 200]
    provider = FakeFlex.new(CURRENT => @current, WINDOW_1 => truncated)

    (IbkrItem::Importer::MAX_HISTORY_FAILURES + 1).times { import(provider) }
    assert_equal [ CURRENT, WINDOW_1 ] * (IbkrItem::Importer::MAX_HISTORY_FAILURES + 1), provider.calls

    import(history_provider)
    assert @account.entries.exists?(external_id: "ibkr_trade_901", source: "ibkr")
  end

  test "a window whose rows fail to import is fetched again by the next sync" do
    Account::ProviderImportAdapter.any_instance.stubs(:import_trade).raises(ActiveRecord::ConnectionNotEstablished, "connection lost")
    provider = history_provider
    assert_equal true, import(provider)[:success]
    assert_equal [ CURRENT, WINDOW_1 ], provider.calls
    assert DebugLogEntry.where(source: "IbkrItem::Importer", provider_key: "ibkr").exists?

    Account::ProviderImportAdapter.any_instance.unstub(:import_trade)
    provider = history_provider
    import(provider)

    assert_equal [ CURRENT, WINDOW_1, WINDOW_2, WINDOW_3, WINDOW_4 ], provider.calls
    assert @account.entries.exists?(external_id: "ibkr_trade_901", source: "ibkr")
  end

  test "a row that keeps failing is skipped after repeated syncs and the walk goes on" do
    bad = %(<CashTransaction type="Deposits/Withdrawals" transactionID="77" amount="100" currency="CHF" fxRateToBase="1" reportDate="2024-06-03" />)
    Account::ProviderImportAdapter.any_instance.stubs(:import_transaction).raises(ActiveRecord::RecordInvalid.new(Entry.new))
    provider = history_provider(WINDOW_1 => window_xml(*WINDOW_1, trade_id: "901", nav_date: "2024-06-03", cash_transaction: bad))

    (IbkrItem::Importer::MAX_HISTORY_FAILURES + 2).times { import(provider) }

    assert_equal IbkrItem::Importer::MAX_HISTORY_FAILURES, provider.calls.count(WINDOW_1)
    assert_equal 1, provider.calls.count(WINDOW_4), "older windows are fetched once the row is skipped: #{provider.calls.inspect}"
    assert @account.entries.exists?(external_id: "ibkr_trade_901", source: "ibkr"), "the window's other rows are kept"
    skipped = DebugLogEntry.where(source: "IbkrItem::Importer", provider_key: "ibkr", level: "error").sole
    assert_includes skipped.message, "cash 77"
  end

  test "a row that keeps failing in one sub-account holds the others back only until it is skipped" do
    other_account = families(:dylan_family).accounts.create!(name: "IBKR Retirement", balance: 0, cash_balance: 0, currency: "USD",
                                                             accountable: Investment.new(subtype: "brokerage"))
    ibkr_accounts(:secondary_account).ensure_account_provider!(other_account)
    bad = %(<CashTransaction type="Deposits/Withdrawals" transactionID="77" amount="100" currency="CHF" fxRateToBase="1" reportDate="2024-06-03" />)
    Account::ProviderImportAdapter.any_instance.stubs(:import_transaction).raises(ActiveRecord::RecordInvalid.new(Entry.new))
    provider = history_provider(
      WINDOW_1 => combined_xml(window_xml(*WINDOW_1, cash_transaction: bad),
                               window_xml(*WINDOW_1, trade_id: "902", nav_date: "2024-06-03", account_id: "U7654321")),
      WINDOW_2 => combined_xml(window_xml(*WINDOW_2), window_xml(*WINDOW_2, trade_id: "802", nav_date: "2023-06-01", account_id: "U7654321"))
    )

    import(provider)
    assert other_account.entries.exists?(external_id: "ibkr_trade_902"), "the other sub-account's rows are imported in the first sync"

    (IbkrItem::Importer::MAX_HISTORY_FAILURES + 1).times { import(provider) }

    assert_equal IbkrItem::Importer::MAX_HISTORY_FAILURES, provider.calls.count(WINDOW_1)
    assert other_account.entries.exists?(external_id: "ibkr_trade_802"), "the other sub-account walks back too: #{provider.calls.inspect}"
  end

  test "a window whose XML never parses is skipped after more syncs than a refused one" do
    bad = window_xml(*WINDOW_1, trade_id: "901", nav_date: "2024-06-03").sub("<OpenPositions />", "<OpenPositions>&</OpenPositions>")
    provider = history_provider(WINDOW_1 => bad)

    (IbkrItem::Importer::MAX_PARSE_FAILURES + 1).times { import(provider) }

    assert_equal IbkrItem::Importer::MAX_PARSE_FAILURES, provider.calls.count(WINDOW_1)
    assert_equal 1, provider.calls.count(WINDOW_2), "older windows are fetched once it is skipped: #{provider.calls.inspect}"
  end

  test "the next sync resumes after the last imported window" do
    throttled = Provider::IbkrFlex::ApiError.new("Too many requests", error_code: "1018")
    import(FakeFlex.new(CURRENT => @current, WINDOW_1 => window_xml(*WINDOW_1, nav_date: "2024-06-03"), WINDOW_2 => throttled))

    provider = FakeFlex.new(CURRENT => @current, WINDOW_2 => window_xml(*WINDOW_2, trade_id: "801", nav_date: "2023-06-01"),
                            WINDOW_3 => window_xml(*WINDOW_3), WINDOW_4 => window_xml(*WINDOW_4))
    import(provider)

    assert_equal [ CURRENT, WINDOW_2, WINDOW_3, WINDOW_4 ], provider.calls
    assert @account.entries.exists?(external_id: "ibkr_trade_801")
  end

  test "no new window is started once the time budget is spent" do
    provider = history_provider(CURRENT => -> { travel IbkrItem::Importer::HISTORY_TIME_BUDGET + 1.second; @current })

    import(provider)

    assert_equal [ CURRENT ], provider.calls
  end

  test "a disabled account is not walked back until it is enabled again" do
    @account.disable!
    provider = history_provider
    import(provider)
    assert_equal [ CURRENT ], provider.calls

    @account.enable!
    import(history_provider)

    assert @account.entries.exists?(external_id: "ibkr_trade_901")
  end

  test "linking the IBKR account to another Sure account walks its history back again" do
    import(history_provider)
    @ibkr_account.account_provider.destroy!
    fresh = new_account(name: "IBKR relinked")
    @ibkr_account.reload.ensure_account_provider!(fresh)

    import(history_provider)

    assert fresh.entries.exists?(external_id: "ibkr_trade_901")
  end

  test "accounts that are not linked are not walked back" do
    @ibkr_account.account_provider.destroy!
    provider = FakeFlex.new(CURRENT => @current)

    import(provider)

    assert_equal [ CURRENT ], provider.calls
  end

  private

    def new_account(name: "IBKR Investment")
      families(:dylan_family).accounts.create!(name: name, balance: 0, cash_balance: 0, currency: "CHF",
                                               accountable: Investment.new(subtype: "brokerage"))
    end

    def history_provider(overrides = {})
      FakeFlex.new({ CURRENT => @current, WINDOW_1 => window_xml(*WINDOW_1, trade_id: "901", nav_date: "2024-06-03"),
                     WINDOW_2 => window_xml(*WINDOW_2), WINDOW_3 => window_xml(*WINDOW_3),
                     WINDOW_4 => window_xml(*WINDOW_4) }.merge(overrides))
    end

    def import(provider)
      IbkrItem::Importer.new(@ibkr_item.reload, ibkr_provider: provider).import
    end

    def window_xml(from_date, to_date, trade_id: nil, nav_date: nil, total: "1000.00", cash: nil, cash_transaction: nil, account_id: "U1234567")
      trade = %(<Trade assetCategory="STK" tradeID="#{trade_id}" transactionID="#{trade_id}a" conid="265598" symbol="AAPL" quantity="1" tradePrice="120.00" currency="USD" fxRateToBase="0.90" buySell="BUY" tradeDate="#{nav_date}" ibCommission="-1.00" ibCommissionCurrency="USD" />) if trade_id
      nav = %(<EquitySummaryByReportDateInBase currency="CHF" reportDate="#{nav_date}" total="#{total}" />) if nav_date
      cash_report = %(<CashReport><CashReportCurrency currency="BASE_SUMMARY" endingCash="#{cash}" /><CashReportCurrency currency="CHF" endingCash="#{cash}" /></CashReport>) if cash

      <<~XML
        <FlexQueryResponse queryName="Sure Test" type="AF">
          <FlexStatements count="1">
            <FlexStatement accountId="#{account_id}" fromDate="#{from_date.iso8601}" toDate="#{to_date.iso8601}">
              <AccountInformation accountId="#{account_id}" currency="CHF" />
              #{cash_report}
              <EquitySummaryInBase>#{nav}</EquitySummaryInBase>
              <OpenPositions />
              <Trades>#{trade}</Trades>
              <CashTransactions>#{cash_transaction}</CashTransactions>
            </FlexStatement>
          </FlexStatements>
        </FlexQueryResponse>
      XML
    end

    # One response holding the statements of several sub-accounts.
    def combined_xml(first, *others)
      statements = others.map { |xml| xml[%r{<FlexStatement .*</FlexStatement>}m] }
      first.sub("</FlexStatements>", "#{statements.join}</FlexStatements>").sub(%(count="1"), %(count="#{others.size + 1}"))
    end
end
