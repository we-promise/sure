require "test_helper"
require "ostruct"

class TradeImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper, ImportInterfaceTest

  setup do
    @subject = @import = imports(:trade)
    @provider = mock
    Security.stubs(:provider).returns(@provider)
  end

  test "csv_template uses ISO dates" do
    first_row = @import.csv_template.first

    assert_equal "2024-05-15", first_row["date*"]
  end

  test "generates rows from legacy quantity header with template labels" do
    import_csv = <<~CSV
      date,ticker,quantity,price,account_name
      2024-05-15,AAPL,10,150.00,Trading Account
    CSV

    @import.update!(
      raw_file_str: import_csv,
      date_col_label: "date*",
      ticker_col_label: "ticker*",
      qty_col_label: "qty*",
      price_col_label: "price*",
      account_col_label: "account",
      date_format: "%Y-%m-%d",
      signage_convention: "inflows_positive"
    )

    @import.generate_rows_from_csv
    row = @import.rows.reload.first

    assert row.valid?
    assert_equal "Trading Account", row.account
    assert_equal "10", row.qty
    assert_equal BigDecimal("1500"), row.signed_amount
  end

  test "imports trades and accounts" do
    aapl_resolver = mock
    googl_resolver = mock

    Security::Resolver.expects(:new)
                      .with("AAPL", exchange_operating_mic: nil)
                      .returns(aapl_resolver)
                      .once

    Security::Resolver.expects(:new)
                      .with("GOOGL", exchange_operating_mic: "XNAS")
                      .returns(googl_resolver)
                      .once

    aapl = securities(:aapl)
    googl = Security.create!(ticker: "GOOGL", exchange_operating_mic: "XNAS")

    aapl_resolver.stubs(:resolve).returns(aapl)
    googl_resolver.stubs(:resolve).returns(googl)

    import = <<~CSV
      date,ticker,qty,price,currency,account,name,exchange_operating_mic
      01/01/2024,AAPL,10,150.00,USD,TestAccount1,Apple Purchase,
      01/02/2024,GOOGL,5,2500.00,USD,TestAccount1,Google Purchase,XNAS
    CSV

    @import.update!(
      account: accounts(:depository),
      raw_file_str: import,
      date_col_label: "date",
      ticker_col_label: "ticker",
      qty_col_label: "qty",
      price_col_label: "price",
      exchange_operating_mic_col_label: "exchange_operating_mic",
      date_format: "%m/%d/%Y",
      signage_convention: "inflows_positive"
    )

    @import.generate_rows_from_csv

    @import.mappings.create! key: "TestAccount1", create_when_empty: true, type: "Import::AccountMapping"

    @import.reload

    assert_difference -> { Entry.count } => 2,
                      -> { Trade.count } => 2,
                      -> { Account.count } => 1 do
      @import.publish
    end

    assert_equal "complete", @import.status
  end

  test "auto-assigns investment activity labels to buy and sell trades" do
    aapl = securities(:aapl)
    aapl_resolver = mock
    aapl_resolver.stubs(:resolve).returns(aapl)
    Security::Resolver.stubs(:new).returns(aapl_resolver)

    account = accounts(:depository)

    import = <<~CSV
      date,ticker,qty,price,currency,name
      01/01/2024,AAPL,10,150.00,USD,Apple Buy
      01/02/2024,AAPL,-5,160.00,USD,Apple Sell
    CSV

    @import.update!(
      account: account,
      raw_file_str: import,
      date_col_label: "date",
      ticker_col_label: "ticker",
      qty_col_label: "qty",
      price_col_label: "price",
      date_format: "%m/%d/%Y",
      signage_convention: "inflows_positive"
    )

    @import.generate_rows_from_csv
    @import.reload

    assert_difference -> { Trade.count } => 2 do
      @import.publish
    end

    # Find trades created by this import
    imported_trades = Trade.joins(:entry).where(entries: { import_id: @import.id })
    buy_trade = imported_trades.find { |t| t.qty.positive? }
    sell_trade = imported_trades.find { |t| t.qty.negative? }

    assert_not_nil buy_trade, "Buy trade should have been created"
    assert_not_nil sell_trade, "Sell trade should have been created"
    assert_equal "Buy", buy_trade.investment_activity_label, "Buy trade should have 'Buy' activity label"
    assert_equal "Sell", sell_trade.investment_activity_label, "Sell trade should have 'Sell' activity label"
  end

  test "mapping_steps includes Import::SecurityMapping for trade imports" do
    assert_includes @import.mapping_steps, Import::SecurityMapping
  end

  test "mapping_steps excludes Import::SecurityMapping for non-trade imports" do
    transaction_import = imports(:transaction)
    assert_not_includes transaction_import.mapping_steps, Import::SecurityMapping
  end

  test "clean-ticker CSV publishes trades with all securities auto-matched" do
    aapl = securities(:aapl)

    import = <<~CSV
      date,ticker,qty,price,currency,name
      01/01/2024,AAPL,10,150.00,USD,Apple Buy
    CSV

    @import.update!(
      account: accounts(:depository),
      raw_file_str: import,
      date_col_label: "date",
      ticker_col_label: "ticker",
      qty_col_label: "qty",
      price_col_label: "price",
      date_format: "%m/%d/%Y",
      signage_convention: "inflows_positive"
    )

    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.reload

    security_mapping = @import.mappings.securities.find_by(key: "AAPL")
    assert_equal aapl, security_mapping.mappable, "clean ticker should be auto-matched with no user action"

    aapl_resolver = mock
    aapl_resolver.stubs(:resolve).returns(aapl)
    Security::Resolver.stubs(:new).returns(aapl_resolver)

    assert_difference -> { Trade.count } => 1 do
      @import.publish
    end

    assert_equal "complete", @import.status
    trade = Trade.joins(:entry).find_by(entries: { import_id: @import.id })
    assert_equal aapl, trade.security
  end

  test "descriptive-label CSV publishes a trade referencing the user-mapped security" do
    bnd = Security.create!(ticker: "BND", exchange_operating_mic: "XNAS", name: "Vanguard Total Bond ETF")

    import = <<~CSV
      date,ticker,qty,price,currency,name
      01/01/2024,VANGUARD TOTAL BOND ETF MARKET,10,80.00,USD,Bond Buy
    CSV

    @import.update!(
      account: accounts(:depository),
      raw_file_str: import,
      date_col_label: "date",
      ticker_col_label: "ticker",
      qty_col_label: "qty",
      price_col_label: "price",
      date_format: "%m/%d/%Y",
      signage_convention: "inflows_positive"
    )

    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.reload

    mapping = @import.mappings.securities.find_by(key: "VANGUARD TOTAL BOND ETF MARKET")
    assert_nil mapping.mappable, "descriptive label should not auto-match"

    # Simulate the user mapping the label to BND via the combobox (mirrors the
    # controller: persist the raw value, then resolve).
    resolver = mock
    resolver.stubs(:resolve).returns(bnd)
    Security::Resolver.stubs(:new).returns(resolver)
    mapping.update_column(:value, "BND|XNAS|")
    mapping.create_mappable!

    assert_difference -> { Trade.count } => 1 do
      @import.publish
    end

    trade = Trade.joins(:entry).find_by(entries: { import_id: @import.id })
    assert_equal bnd, trade.security
    assert_not trade.security.offline?, "mapped security should not be marked offline for a descriptive label"
  end

  test "import is not publishable while a descriptive label is unresolved" do
    @import.update!(
      account: accounts(:depository),
      raw_file_str: "date,ticker,qty,price,currency,name\n01/01/2024,VANGUARD TOTAL BOND ETF MARKET,10,80.00,USD,Bond Buy\n",
      date_col_label: "date",
      ticker_col_label: "ticker",
      qty_col_label: "qty",
      price_col_label: "price",
      date_format: "%m/%d/%Y",
      signage_convention: "inflows_positive"
    )

    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.reload

    mapping = @import.mappings.securities.find_by(key: "VANGUARD TOTAL BOND ETF MARKET")
    assert_nil mapping.mappable
    assert_not mapping.valid?
    assert_not @import.publishable?, "an unresolved security label must block publishing"
  end

  test "a new ticker absent from the local DB must be mapped once before publishing" do
    @import.update!(
      account: accounts(:depository),
      raw_file_str: "date,ticker,qty,price,currency,name\n01/01/2024,TSLA,2,700.00,USD,Tesla Buy\n",
      date_col_label: "date",
      ticker_col_label: "ticker",
      qty_col_label: "qty",
      price_col_label: "price",
      date_format: "%m/%d/%Y",
      signage_convention: "inflows_positive"
    )

    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.reload

    mapping = @import.mappings.securities.find_by(key: "TSLA")
    assert_nil mapping.mappable, "a ticker absent from the local DB is not auto-matched"
    assert_not @import.publishable?, "an unresolved security must block publishing (hard gate)"

    # User confirms the ticker via the combobox (resolve-on-update). The
    # resolver creates/returns the real security at selection time.
    tsla = Security.create!(ticker: "TSLA", exchange_operating_mic: "XNAS", name: "Tesla")
    resolver = mock
    resolver.stubs(:resolve).returns(tsla)
    Security::Resolver.stubs(:new).returns(resolver)
    mapping.update_column(:value, "TSLA|XNAS|")
    mapping.create_mappable!
    @import.reload

    assert @import.publishable?, "once mapped, the import is publishable"

    assert_difference -> { Trade.count } => 1 do
      @import.publish
    end

    assert_equal "complete", @import.status
    trade = Trade.joins(:entry).find_by(entries: { import_id: @import.id })
    assert_equal tsla, trade.security
  end
end
