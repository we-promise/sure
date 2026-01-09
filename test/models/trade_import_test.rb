require "test_helper"
require "ostruct"

class TradeImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper, ImportInterfaceTest

  setup do
    @subject = @import = imports(:trade)
    @provider = mock
    Security.stubs(:provider).returns(@provider)
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

  test "auto-categorizes buy trades and leaves sell trades uncategorized" do
    aapl = securities(:aapl)
    aapl_resolver = mock
    aapl_resolver.stubs(:resolve).returns(aapl)
    Security::Resolver.stubs(:new).returns(aapl_resolver)

    # Create the investment category if it doesn't exist
    account = accounts(:depository)
    family = account.family
    savings_category = family.categories.find_or_create_by!(name: "Savings & Investments") do |c|
      c.color = "#059669"
      c.classification = "expense"
      c.lucide_icon = "piggy-bank"
    end

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
    assert_equal savings_category, buy_trade.category, "Buy trade should be auto-categorized as Savings & Investments"
    assert_nil sell_trade.category, "Sell trade should not be auto-categorized"
  end
end
