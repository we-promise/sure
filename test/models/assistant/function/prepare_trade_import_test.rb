require "test_helper"

# The tool prepares a trade CSV with the manual import's own
# steps and leaves it pending: nothing reaches the user's accounts.
class Assistant::Function::PrepareTradeImportTest < ActiveSupport::TestCase
  BROKER_CSV = <<~CSV
    Trade Date,Symbol,Quantity,Price,Currency,Description
    05/03/2026,AAPL,10,150.00,USD,Bought Apple
    06/03/2026,MSFT,-2,410.50,USD,Sold Microsoft
  CSV

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:investment)
    @fn = Assistant::Function::PrepareTradeImport.new(@user)
  end

  # The same CSV mapped by hand through the manual flow's
  # steps (ImportsController#create, UploadsController#update,
  # ConfigurationsController#update) gives exactly the rows the tool gives.
  test "the rows are the rows the manual mapping produces for the same choices" do
    result = @fn.call("csv_content" => BROKER_CSV, "account_id" => @account.id)
    tool_import = @family.imports.find(result[:import_id])

    manual = @family.imports.create!(type: "TradeImport", account: @account, date_format: @family.date_format)
    manual.update!(raw_file_str: BROKER_CSV, col_sep: ",")
    manual.update!(
      date_col_label: "Trade Date", ticker_col_label: "Symbol", qty_col_label: "Quantity",
      price_col_label: "Price", currency_col_label: "Currency", name_col_label: "Description",
      date_format: tool_import.date_format, number_format: "1,234.56", signage_convention: "inflows_positive"
    )
    manual.generate_rows_from_csv
    manual.reload.sync_mappings

    comparable = ->(import) { import.rows.ordered.map { |row| row.attributes.except("id", "import_id", "created_at", "updated_at") } }
    assert_equal 2, comparable.call(manual).size
    assert_equal comparable.call(manual), comparable.call(tool_import)
  end

  test "a broker's headers are mapped to the import's columns" do
    result = @fn.call("csv_content" => BROKER_CSV, "account_id" => @account.id)

    assert_equal(
      { "date" => "Trade Date", "ticker" => "Symbol", "qty" => "Quantity", "price" => "Price", "currency" => "Currency", "name" => "Description" },
      result[:column_mapping]
    )
    assert_equal 2, result[:valid_rows_count]
    assert_equal %w[AAPL MSFT], result[:tickers]
  end

  test "the date format is detected from the dates in the file" do
    result = @fn.call("csv_content" => BROKER_CSV.sub("05/03/2026", "25/03/2026"), "account_id" => @account.id)

    assert_equal "%d/%m/%Y", result[:date_format]
  end

  test "a US-dated file is detected as month first" do
    result = @fn.call("csv_content" => BROKER_CSV.sub("05/03/2026", "03/25/2026"), "account_id" => @account.id)

    assert_equal "%m/%d/%Y", result[:date_format]
    assert_equal false, result[:date_format_ambiguous]
  end

  # Every day in BROKER_CSV is 12 or under, so day first and month first
  # both read every date, as different dates.
  test "a file whose dates read both day first and month first says so" do
    result = @fn.call("csv_content" => BROKER_CSV, "account_id" => @account.id)

    assert_equal "%d/%m/%Y", result[:date_format]
    assert_equal true, result[:date_format_ambiguous]
    assert_equal [ "%m/%d/%Y" ], result[:date_format_alternatives]
  end

  test "a file with a day over 12 is not ambiguous" do
    result = @fn.call("csv_content" => BROKER_CSV.sub("05/03/2026", "25/03/2026"), "account_id" => @account.id)

    assert_equal false, result[:date_format_ambiguous]
    assert_equal [], result[:date_format_alternatives]
  end

  # Fifty distinct dates that read both ways, then one only month first can
  # read: the whole file decides the format, not its first fifty dates.
  test "a date past the first fifty that reads only month first decides the format" do
    ambiguous = (1..12).to_a.product((1..12).to_a).first(50).map { |month, day| format("%02d/%02d/2025", month, day) }
    lines = (ambiguous + [ "03/25/2026" ]).map { |date| "#{date},AAPL,1,150.00,USD,Bought Apple" }
    csv = "Trade Date,Symbol,Quantity,Price,Currency,Description\n#{lines.join("\n")}\n"

    result = @fn.call("csv_content" => csv, "account_id" => @account.id)

    assert_equal "%m/%d/%Y", result[:date_format]
    assert_equal 51, result[:valid_rows_count]
    assert_empty result[:invalid_rows]
    assert_equal false, result[:date_format_ambiguous]
  end

  # Date.strptime reads 13/01/2025 under %d/%m/%y as 13 January 2020 and
  # ignores the trailing "25". A format that reads any date only in part is
  # not chosen, so one short year cannot move every other date.
  test "a format that reads a date only in part is not chosen" do
    full_years = (13..28).to_a.product([ 1, 2, 3, 4 ]).first(50).map { |day, month| format("%02d/%02d/2025", day, month) }
    lines = (full_years + [ "05/03/25" ]).map { |date| "#{date},AAPL,1,150.00,USD,Bought Apple" }
    csv = "Trade Date,Symbol,Quantity,Price,Currency,Description\n#{lines.join("\n")}\n"

    result = @fn.call("csv_content" => csv, "account_id" => @account.id)

    assert_equal "%d/%m/%Y", result[:date_format]
    assert_equal 50, result[:valid_rows_count]
    assert_equal [ 51 ], result[:invalid_rows].map { |row| row[:row_number] }
  end

  # No format reads a date with a time after it whole, so that rules no
  # format out, and the rows still read as they did before.
  test "dates with a time after them still decide the format" do
    # The fallback must not be the answer, or the test proves nothing.
    @family.update!(date_format: "%d/%m/%Y")
    csv = "Trade Date,Symbol,Quantity,Price,Currency,Description\n" \
          "2026-03-05 10:30:00,AAPL,10,150.00,USD,Bought Apple\n" \
          "2026-03-06 15:00:00,MSFT,-2,410.50,USD,Sold Microsoft\n"

    result = @fn.call("csv_content" => csv, "account_id" => @account.id)

    assert_equal "%Y-%m-%d", result[:date_format]
    assert_equal 2, result[:valid_rows_count]
  end

  # An unreadable date is reported as an invalid row; it must not also hide
  # that every other date reads two ways.
  test "an unreadable date does not hide that the other dates read two ways" do
    csv = BROKER_CSV + "not a date,AAPL,1,150.00,USD,Bought Apple\n"

    result = @fn.call("csv_content" => csv, "account_id" => @account.id)

    assert_equal "%d/%m/%Y", result[:date_format]
    assert_equal true, result[:date_format_ambiguous]
    assert_equal [ "%m/%d/%Y" ], result[:date_format_alternatives]
    assert_equal 1, result[:invalid_rows].size
  end

  test "a date format the caller passes is not reported as ambiguous" do
    result = @fn.call("csv_content" => BROKER_CSV, "account_id" => @account.id, "date_format" => "%m/%d/%Y")

    assert_equal "%m/%d/%Y", result[:date_format]
    assert_equal false, result[:date_format_ambiguous]
  end

  test "nothing reaches the user's accounts: no entry, trade or security is written" do
    assert_no_difference [ "Entry.count", "Trade.count", "Security.count" ] do
      assert_difference "Import.count", 1 do
        @fn.call("csv_content" => BROKER_CSV, "account_id" => @account.id)
      end
    end

    assert_equal "pending", Import.order(:created_at).last.status
  end

  test "an explicit column mapping overrides detection" do
    csv = "When,Code,Units,Cost\n2026-03-05,AAPL,10,150\n"
    result = @fn.call("csv_content" => csv, "account_id" => @account.id,
                      "column_mapping" => { "date" => "When", "ticker" => "Code", "qty" => "Units", "price" => "Cost" })

    assert_equal({ "date" => "When", "ticker" => "Code", "qty" => "Units", "price" => "Cost" }, result[:column_mapping])
    assert_equal 1, result[:valid_rows_count]
  end

  test "a missing required column creates no import and says which" do
    csv = "When,Code,Units\n2026-03-05,AAPL,10\n"

    result = assert_no_difference("Import.count") { @fn.call("csv_content" => csv, "account_id" => @account.id) }

    assert_equal "columns_not_found", result[:error]
    assert_includes result[:message], "date"
    assert_includes result[:message], "price"
    assert_equal %w[When Code Units], result[:headers]
  end

  test "a mapping to a header the file does not have is refused" do
    result = assert_no_difference("Import.count") do
      @fn.call("csv_content" => BROKER_CSV, "account_id" => @account.id, "column_mapping" => { "date" => "Settlement" })
    end

    assert_equal "invalid_column_mapping", result[:error]
  end

  # The import's own header check runs while the rows are generated, after
  # the import has been saved. A refusal there must not leave the import behind.
  test "headers that differ only by case are refused and create no import" do
    csv = "Date,Ticker,Qty,Price,date\n2026-03-05,AAPL,10,150,2026-03-06\n"

    result = assert_no_difference("Import.count") { @fn.call("csv_content" => csv, "account_id" => @account.id) }

    assert_equal "import_invalid", result[:error]
    assert_includes result[:message], "Date, date"
  end

  test "rows that will not import are listed with their row numbers" do
    csv = BROKER_CSV + "31/31/2026,TSLA,1,700,USD,Bad date\n"

    result = @fn.call("csv_content" => csv, "account_id" => @account.id)

    assert_equal 3, result[:rows_count]
    assert_equal 2, result[:valid_rows_count]
    assert_equal [ 3 ], result[:invalid_rows].map { |row| row[:row_number] }
  end

  test "without an account the account column is mapped and new accounts are counted" do
    csv = "Date,Ticker,Qty,Price,Account\n2026-03-05,AAPL,10,150,Brand New Brokerage\n"

    result = @fn.call("csv_content" => csv)

    assert_equal "Account", result[:column_mapping]["account"]
    assert_equal 1, result[:accounts_to_create]
  end

  # The boundary is access, not family: a member's account in the same family
  # that was never shared with this user is refused too.
  test "an account the user cannot access is refused, even in their own family" do
    other = @family.accounts.create!(name: "Member's own", balance: 0, currency: "USD", accountable: Investment.new, owner: users(:family_member))
    other.account_shares.destroy_all

    result = assert_no_difference("Import.count") { @fn.call("csv_content" => BROKER_CSV, "account_id" => other.id) }

    assert_equal "account_not_found", result[:error]
  end

  test "an empty, header-only or oversized file is refused" do
    assert_equal "csv_required", @fn.call("csv_content" => "")[:error]
    assert_equal "csv_invalid", @fn.call("csv_content" => "Date,Ticker,Qty,Price\n", "account_id" => @account.id)[:error]

    Import.stubs(:max_csv_size).returns(10)
    assert_equal "csv_too_large", @fn.call("csv_content" => BROKER_CSV)[:error]
  end

  test "a semicolon-separated file is read" do
    csv = "Date;Ticker;Qty;Price\n2026-03-05;AAPL;10;150\n"

    result = @fn.call("csv_content" => csv, "account_id" => @account.id)

    assert_equal 1, result[:valid_rows_count]
  end

  test "the tool is offered only with preview features" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    assert_not_includes Assistant.function_classes(@user).map(&:name), "prepare_trade_import"

    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    assert_includes Assistant.function_classes(@user).map(&:name), "prepare_trade_import"
  end
end
