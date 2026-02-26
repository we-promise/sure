require "test_helper"

class QifImportTest < ActiveSupport::TestCase
  # ── QifParser unit tests ────────────────────────────────────────────────────

  SAMPLE_QIF = <<~QIF
    !Type:Tag
    NTRIP2025
    ^
    NVACATION2023
    DSummer Vacation 2023
    ^
    !Type:Cat
    NFood & Dining
    DFood and dining expenses
    E
    ^
    NFood & Dining:Restaurants
    DRestaurants
    E
    ^
    NSalary
    DSalary Income
    I
    ^
    !Type:CCard
    D6/ 4'20
    U-99.00
    T-99.00
    C*
    NTXFR
    PMerchant A
    LFees & Charges
    ^
    D3/29'21
    U-28,500.00
    T-28,500.00
    PTransfer Out
    L[Savings Account]
    ^
    D10/ 1'20
    U500.00
    T500.00
    PPayment Received
    LFood & Dining/TRIP2025
    ^
  QIF

  QIF_WITH_HIERARCHICAL_CATEGORIES = <<~QIF
    !Type:Bank
    D1/ 1'24
    U-150.00
    T-150.00
    PHardware Store
    LHome:Home Improvement
    ^
    D2/ 1'24
    U-50.00
    T-50.00
    PGrocery Store
    LFood:Groceries
    ^
  QIF

  # A QIF file that includes an Opening Balance entry as the first transaction.
  # This mirrors how Quicken exports bank accounts.
  QIF_WITH_OPENING_BALANCE = <<~QIF
    !Type:Bank
    D1/ 1'20
    U500.00
    T500.00
    POpening Balance
    L[Checking Account]
    ^
    D3/ 1'20
    U100.00
    T100.00
    PFirst Deposit
    ^
    D4/ 1'20
    U-25.00
    T-25.00
    PCoffee Shop
    ^
  QIF

  # A minimal investment QIF with two securities, trades, a dividend, and a cash transfer.
  SAMPLE_INVST_QIF = <<~QIF
    !Type:Security
    NACME
    SACME
    TStock
    ^
    !Type:Security
    NCORP
    SCORP
    TStock
    ^
    !Type:Invst
    D1/17'22
    NDiv
    YACME
    U190.75
    T190.75
    ^
    D1/17'22
    NBuy
    YACME
    I66.10
    Q2
    U132.20
    T132.20
    ^
    D1/ 7'22
    NXIn
    PMonthly Deposit
    U8000.00
    T8000.00
    ^
    D2/ 1'22
    NSell
    YCORP
    I45.00
    Q3
    U135.00
    T135.00
    ^
  QIF

  # ── QifParser: valid? ───────────────────────────────────────────────────────

  test "valid? returns true for QIF content" do
    assert QifParser.valid?(SAMPLE_QIF)
  end

  test "valid? returns false for non-QIF content" do
    refute QifParser.valid?("<OFX><STMTTRN></STMTTRN></OFX>")
    refute QifParser.valid?("date,amount,name\n2024-01-01,100,Coffee")
    refute QifParser.valid?(nil)
    refute QifParser.valid?("")
  end

  # ── QifParser: account_type ─────────────────────────────────────────────────

  test "account_type extracts transaction section type" do
    assert_equal "CCard", QifParser.account_type(SAMPLE_QIF)
  end

  test "account_type ignores Tag and Cat sections" do
    qif = "!Type:Tag\nNMyTag\n^\n!Type:Cat\nNMyCat\n^\n!Type:Bank\nD1/1'24\nT100.00\nPTest\n^\n"
    assert_equal "Bank", QifParser.account_type(qif)
  end

  # ── QifParser: parse (transactions) ─────────────────────────────────────────

  test "parse returns correct number of transactions" do
    assert_equal 3, QifParser.parse(SAMPLE_QIF).length
  end

  test "parse extracts dates correctly" do
    transactions = QifParser.parse(SAMPLE_QIF)
    assert_equal "2020-06-04", transactions[0].date
    assert_equal "2021-03-29", transactions[1].date
    assert_equal "2020-10-01", transactions[2].date
  end

  test "parse extracts negative amount with commas" do
    assert_equal "-28500.00", QifParser.parse(SAMPLE_QIF)[1].amount
  end

  test "parse extracts simple negative amount" do
    assert_equal "-99.00", QifParser.parse(SAMPLE_QIF)[0].amount
  end

  test "parse extracts payee" do
    transactions = QifParser.parse(SAMPLE_QIF)
    assert_equal "Merchant A",   transactions[0].payee
    assert_equal "Transfer Out", transactions[1].payee
  end

  test "parse extracts category and ignores transfer accounts" do
    transactions = QifParser.parse(SAMPLE_QIF)
    assert_equal "Fees & Charges", transactions[0].category
    assert_equal "",               transactions[1].category  # [Savings Account] = transfer
    assert_equal "Food & Dining",  transactions[2].category
  end

  test "parse extracts tags from L field slash suffix" do
    transactions = QifParser.parse(SAMPLE_QIF)
    assert_equal [],             transactions[0].tags
    assert_equal [],             transactions[1].tags
    assert_equal [ "TRIP2025" ], transactions[2].tags
  end

  # ── QifParser: parse_categories ─────────────────────────────────────────────

  test "parse_categories returns all categories" do
    names = QifParser.parse_categories(SAMPLE_QIF).map(&:name)
    assert_includes names, "Food & Dining"
    assert_includes names, "Food & Dining:Restaurants"
    assert_includes names, "Salary"
  end

  test "parse_categories marks income vs expense correctly" do
    categories = QifParser.parse_categories(SAMPLE_QIF)
    salary = categories.find { |c| c.name == "Salary" }
    food   = categories.find { |c| c.name == "Food & Dining" }
    assert salary.income
    refute food.income
  end

  # ── QifParser: parse_tags ───────────────────────────────────────────────────

  test "parse_tags returns all tags" do
    names = QifParser.parse_tags(SAMPLE_QIF).map(&:name)
    assert_includes names, "TRIP2025"
    assert_includes names, "VACATION2023"
  end

  test "parse_tags captures description" do
    vacation = QifParser.parse_tags(SAMPLE_QIF).find { |t| t.name == "VACATION2023" }
    assert_equal "Summer Vacation 2023", vacation.description
  end

  # ── QifParser: encoding ──────────────────────────────────────────────────────

  test "normalize_encoding returns content unchanged when already valid UTF-8" do
    result = QifParser.normalize_encoding("!Type:CCard\n")
    assert_equal "!Type:CCard\n", result
  end

  # ── QifParser: opening balance ───────────────────────────────────────────────

  test "parse skips Opening Balance transaction" do
    transactions = QifParser.parse(QIF_WITH_OPENING_BALANCE)
    assert_equal 2, transactions.length
    refute transactions.any? { |t| t.payee == "Opening Balance" }
  end

  test "parse_opening_balance returns date and amount" do
    ob = QifParser.parse_opening_balance(QIF_WITH_OPENING_BALANCE)
    assert_not_nil ob
    assert_equal Date.new(2020, 1, 1), ob[:date]
    assert_equal BigDecimal("500"),    ob[:amount]
  end

  test "parse_opening_balance returns nil when no Opening Balance entry" do
    assert_nil QifParser.parse_opening_balance(SAMPLE_QIF)
  end

  test "parse_opening_balance returns nil for blank content" do
    assert_nil QifParser.parse_opening_balance(nil)
    assert_nil QifParser.parse_opening_balance("")
  end

  # ── QifImport model ─────────────────────────────────────────────────────────

  setup do
    @family  = families(:dylan_family)
    @account = accounts(:depository)
    @import  = QifImport.create!(family: @family, account: @account)
  end

  test "generates rows from QIF content" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    assert_equal 3, @import.rows.count
  end

  test "rows_count is updated after generate_rows_from_csv" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    assert_equal 3, @import.reload.rows_count
  end

  test "generates row with correct date and amount" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    row = @import.rows.find_by(name: "Merchant A")
    assert_equal "2020-06-04", row.date
    assert_equal "-99.00",     row.amount
  end

  test "generates row with category" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    row = @import.rows.find_by(name: "Merchant A")
    assert_equal "Fees & Charges", row.category
  end

  test "generates row with tags stored as pipe-separated string" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    row = @import.rows.find_by(name: "Payment Received")
    assert_equal "TRIP2025", row.tags
  end

  test "transfer rows have blank category" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    row = @import.rows.find_by(name: "Transfer Out")
    assert row.category.blank?
  end

  test "requires_csv_workflow? is false" do
    refute @import.requires_csv_workflow?
  end

  test "qif_account_type returns CCard for credit card QIF" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    assert_equal "CCard", @import.qif_account_type
  end

  test "row_categories excludes blank categories" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    cats = @import.row_categories
    assert_includes cats, "Fees & Charges"
    assert_includes cats, "Food & Dining"
    refute_includes cats, ""
  end

  test "row_tags excludes blank tags" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    tags = @import.row_tags
    assert_includes tags, "TRIP2025"
    refute_includes tags, ""
  end

  test "categories_selected? is false before sync_mappings" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    refute @import.categories_selected?
  end

  test "categories_selected? is true after sync_mappings" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv
    @import.sync_mappings

    assert @import.categories_selected?
  end

  test "publishable? requires account to be present" do
    import_without_account = QifImport.create!(family: @family)
    import_without_account.update_columns(raw_file_str: SAMPLE_QIF, rows_count: 1)

    refute import_without_account.publishable?
  end

  # ── Opening balance handling ─────────────────────────────────────────────────

  test "Opening Balance row is not generated as a transaction row" do
    @import.update!(raw_file_str: QIF_WITH_OPENING_BALANCE)
    @import.generate_rows_from_csv

    assert_equal 2, @import.rows.count
    refute @import.rows.exists?(name: "Opening Balance")
  end

  test "import! sets opening anchor from QIF Opening Balance entry" do
    @import.update!(raw_file_str: QIF_WITH_OPENING_BALANCE)
    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.import!

    manager = Account::OpeningBalanceManager.new(@account)
    assert manager.has_opening_anchor?
    assert_equal Date.new(2020, 1, 1), manager.opening_date
    assert_equal BigDecimal("500"),    manager.opening_balance
  end

  test "import! moves opening anchor back when transactions predate it" do
    # Anchor set 2 years ago; SAMPLE_QIF has transactions from 2020 which predate it
    @account.entries.create!(
      date:      2.years.ago.to_date,
      name:      "Opening balance",
      amount:    0,
      currency:  @account.currency,
      entryable: Valuation.new(kind: "opening_anchor")
    )

    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.import!

    manager = Account::OpeningBalanceManager.new(@account.reload)
    # Day before the earliest SAMPLE_QIF transaction (2020-06-04)
    assert_equal Date.new(2020, 6, 3), manager.opening_date
    assert_equal 0, manager.opening_balance
  end

  test "import! does not move opening anchor when transactions do not predate it" do
    anchor_date = Date.new(2020, 1, 1) # before the earliest SAMPLE_QIF transaction (2020-06-04)
    @account.entries.create!(
      date:      anchor_date,
      name:      "Opening balance",
      amount:    0,
      currency:  @account.currency,
      entryable: Valuation.new(kind: "opening_anchor")
    )

    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.import!

    assert_equal anchor_date, Account::OpeningBalanceManager.new(@account.reload).opening_date
  end

  test "import! updates a pre-existing opening anchor from QIF Opening Balance entry" do
    @account.entries.create!(
      date:      2.years.ago.to_date,
      name:      "Opening balance",
      amount:    0,
      currency:  @account.currency,
      entryable: Valuation.new(kind: "opening_anchor")
    )

    @import.update!(raw_file_str: QIF_WITH_OPENING_BALANCE)
    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.import!

    manager = Account::OpeningBalanceManager.new(@account.reload)
    assert_equal Date.new(2020, 1, 1), manager.opening_date
    assert_equal BigDecimal("500"),    manager.opening_balance
  end

  test "will_adjust_opening_anchor? returns true when transactions predate anchor" do
    @account.entries.create!(
      date:      2.years.ago.to_date,
      name:      "Opening balance",
      amount:    0,
      currency:  @account.currency,
      entryable: Valuation.new(kind: "opening_anchor")
    )

    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    assert @import.will_adjust_opening_anchor?
  end

  test "will_adjust_opening_anchor? returns false when QIF has Opening Balance entry" do
    @account.entries.create!(
      date:      2.years.ago.to_date,
      name:      "Opening balance",
      amount:    0,
      currency:  @account.currency,
      entryable: Valuation.new(kind: "opening_anchor")
    )

    @import.update!(raw_file_str: QIF_WITH_OPENING_BALANCE)
    @import.generate_rows_from_csv

    refute @import.will_adjust_opening_anchor?
  end

  test "adjusted_opening_anchor_date is one day before earliest transaction" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    assert_equal Date.new(2020, 6, 3), @import.adjusted_opening_anchor_date
  end

  # ── Hierarchical category (Parent:Child) ─────────────────────────────────────

  test "generates rows with hierarchical category stored as-is" do
    @import.update!(raw_file_str: QIF_WITH_HIERARCHICAL_CATEGORIES)
    @import.generate_rows_from_csv

    row = @import.rows.find_by(name: "Hardware Store")
    assert_equal "Home:Home Improvement", row.category
  end

  test "create_mappable! creates parent and child categories for hierarchical key" do
    @import.update!(raw_file_str: QIF_WITH_HIERARCHICAL_CATEGORIES)
    @import.generate_rows_from_csv
    @import.sync_mappings

    mapping = @import.mappings.categories.find_by(key: "Home:Home Improvement")
    mapping.update!(create_when_empty: true)
    mapping.create_mappable!

    child = @family.categories.find_by(name: "Home Improvement")
    assert_not_nil child
    assert_not_nil child.parent
    assert_equal "Home", child.parent.name
  end

  test "create_mappable! reuses existing parent category for hierarchical key" do
    existing_parent = @family.categories.create!(
      name: "Home", color: "#aabbcc", lucide_icon: "house", classification: "expense"
    )

    @import.update!(raw_file_str: QIF_WITH_HIERARCHICAL_CATEGORIES)
    @import.generate_rows_from_csv
    @import.sync_mappings

    mapping = @import.mappings.categories.find_by(key: "Home:Home Improvement")
    mapping.update!(create_when_empty: true)

    assert_no_difference "@family.categories.where(name: 'Home').count" do
      mapping.create_mappable!
    end

    child = @family.categories.find_by(name: "Home Improvement")
    assert_equal existing_parent.id, child.parent_id
  end

  test "mappables_by_key pre-matches hierarchical key to existing child category" do
    parent = @family.categories.create!(
      name: "Home", color: "#aabbcc", lucide_icon: "house", classification: "expense"
    )
    child = @family.categories.create!(
      name: "Home Improvement", color: "#aabbcc", lucide_icon: "house",
      classification: "expense", parent: parent
    )

    @import.update!(raw_file_str: QIF_WITH_HIERARCHICAL_CATEGORIES)
    @import.generate_rows_from_csv

    mappables = Import::CategoryMapping.mappables_by_key(@import)
    assert_equal child, mappables["Home:Home Improvement"]
  end

  # ── Investment (Invst) QIF: parser ──────────────────────────────────────────

  test "parse_securities returns all securities from investment QIF" do
    securities = QifParser.parse_securities(SAMPLE_INVST_QIF)
    assert_equal 2, securities.length
    tickers = securities.map(&:ticker)
    assert_includes tickers, "ACME"
    assert_includes tickers, "CORP"
  end

  test "parse_securities maps name to ticker and type correctly" do
    acme = QifParser.parse_securities(SAMPLE_INVST_QIF).find { |s| s.ticker == "ACME" }
    assert_equal "ACME",  acme.name
    assert_equal "Stock", acme.security_type
  end

  test "parse_securities returns empty array for non-investment QIF" do
    assert_empty QifParser.parse_securities(SAMPLE_QIF)
  end

  test "parse_investment_transactions returns all investment records" do
    assert_equal 4, QifParser.parse_investment_transactions(SAMPLE_INVST_QIF).length
  end

  test "parse_investment_transactions resolves security name to ticker" do
    buy = QifParser.parse_investment_transactions(SAMPLE_INVST_QIF).find { |t| t.action == "Buy" }
    assert_equal "ACME", buy.security_ticker
    assert_equal "ACME", buy.security_name
  end

  test "parse_investment_transactions extracts price, qty, and amount for trade actions" do
    buy = QifParser.parse_investment_transactions(SAMPLE_INVST_QIF).find { |t| t.action == "Buy" }
    assert_equal "66.10",  buy.price
    assert_equal "2",      buy.qty
    assert_equal "132.20", buy.amount
  end

  test "parse_investment_transactions extracts amount and ticker for dividend" do
    div = QifParser.parse_investment_transactions(SAMPLE_INVST_QIF).find { |t| t.action == "Div" }
    assert_equal "190.75", div.amount
    assert_equal "ACME",   div.security_ticker
  end

  test "parse_investment_transactions extracts payee for cash actions" do
    xin = QifParser.parse_investment_transactions(SAMPLE_INVST_QIF).find { |t| t.action == "XIn" }
    assert_equal "Monthly Deposit", xin.payee
    assert_equal "8000.00",         xin.amount
  end

  # ── Investment (Invst) QIF: row generation ──────────────────────────────────

  test "qif_account_type returns Invst for investment QIF" do
    @import.update!(raw_file_str: SAMPLE_INVST_QIF)
    assert_equal "Invst", @import.qif_account_type
  end

  test "generates correct number of rows from investment QIF" do
    @import.update!(raw_file_str: SAMPLE_INVST_QIF)
    @import.generate_rows_from_csv

    assert_equal 4, @import.rows.count
  end

  test "generates trade rows with correct entity_type, ticker, qty, and price" do
    @import.update!(raw_file_str: SAMPLE_INVST_QIF)
    @import.generate_rows_from_csv

    buy_row = @import.rows.find_by(entity_type: "Buy")
    assert_not_nil buy_row
    assert_equal "ACME",   buy_row.ticker
    assert_equal "2.0",    buy_row.qty
    assert_equal "66.10",  buy_row.price
    assert_equal "132.20", buy_row.amount
  end

  test "generates sell row with negative qty" do
    @import.update!(raw_file_str: SAMPLE_INVST_QIF)
    @import.generate_rows_from_csv

    sell_row = @import.rows.find_by(entity_type: "Sell")
    assert_not_nil sell_row
    assert_equal "CORP", sell_row.ticker
    assert_equal "-3.0", sell_row.qty
  end

  test "generates transaction row for Div with security name in row name" do
    @import.update!(raw_file_str: SAMPLE_INVST_QIF)
    @import.generate_rows_from_csv

    div_row = @import.rows.find_by(entity_type: "Div")
    assert_not_nil div_row
    assert_equal "Dividend: ACME", div_row.name
    assert_equal "190.75",         div_row.amount
  end

  test "generates transaction row for XIn using payee as name" do
    @import.update!(raw_file_str: SAMPLE_INVST_QIF)
    @import.generate_rows_from_csv

    xin_row = @import.rows.find_by(entity_type: "XIn")
    assert_not_nil xin_row
    assert_equal "Monthly Deposit", xin_row.name
  end

  # ── Investment (Invst) QIF: import! ─────────────────────────────────────────

  test "import! creates Trade records for buy and sell rows" do
    import = QifImport.create!(family: @family, account: accounts(:investment))
    import.update!(raw_file_str: SAMPLE_INVST_QIF)
    import.generate_rows_from_csv
    import.sync_mappings

    Security::Resolver.any_instance.stubs(:resolve).returns(securities(:aapl))

    assert_difference "Trade.count", 2 do
      import.import!
    end
  end

  test "import! creates Transaction records for dividend and cash rows" do
    import = QifImport.create!(family: @family, account: accounts(:investment))
    import.update!(raw_file_str: SAMPLE_INVST_QIF)
    import.generate_rows_from_csv
    import.sync_mappings

    Security::Resolver.any_instance.stubs(:resolve).returns(securities(:aapl))

    assert_difference "Transaction.count", 2 do
      import.import!
    end
  end

  test "import! creates inflow Entry for Div (negative amount)" do
    import = QifImport.create!(family: @family, account: accounts(:investment))
    import.update!(raw_file_str: SAMPLE_INVST_QIF)
    import.generate_rows_from_csv
    import.sync_mappings

    Security::Resolver.any_instance.stubs(:resolve).returns(securities(:aapl))
    import.import!

    div_entry = accounts(:investment).entries.find_by(name: "Dividend: ACME")
    assert_not_nil div_entry
    assert div_entry.amount.negative?, "Dividend should be an inflow (negative amount)"
    assert_in_delta(-190.75, div_entry.amount, 0.01)
  end

  test "import! creates outflow Entry for Buy (positive amount)" do
    import = QifImport.create!(family: @family, account: accounts(:investment))
    import.update!(raw_file_str: SAMPLE_INVST_QIF)
    import.generate_rows_from_csv
    import.sync_mappings

    Security::Resolver.any_instance.stubs(:resolve).returns(securities(:aapl))
    import.import!

    buy_entry = accounts(:investment)
      .entries
      .joins("INNER JOIN trades ON trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'")
      .find_by("trades.qty > 0")
    assert_not_nil buy_entry
    assert buy_entry.amount.positive?, "Buy trade should be an outflow (positive amount)"
  end

  test "import! creates inflow Entry for Sell (negative amount)" do
    import = QifImport.create!(family: @family, account: accounts(:investment))
    import.update!(raw_file_str: SAMPLE_INVST_QIF)
    import.generate_rows_from_csv
    import.sync_mappings

    Security::Resolver.any_instance.stubs(:resolve).returns(securities(:aapl))
    import.import!

    sell_entry = accounts(:investment)
      .entries
      .joins("INNER JOIN trades ON trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'")
      .find_by("trades.qty < 0")
    assert_not_nil sell_entry
    assert sell_entry.amount.negative?, "Sell trade should be an inflow (negative amount)"
  end

  test "will_adjust_opening_anchor? returns false for investment accounts" do
    import = QifImport.create!(family: @family, account: accounts(:investment))
    import.update!(raw_file_str: SAMPLE_INVST_QIF)
    import.generate_rows_from_csv

    refute import.will_adjust_opening_anchor?
  end
end
