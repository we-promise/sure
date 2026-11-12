require "test_helper"

class MonarchImport::ConverterTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @exports = MonarchImport::Exports.new(
      balances_csv: file_fixture("imports/monarch_balances.csv").read,
      transactions_csv: file_fixture("imports/monarch_transactions.csv").read
    )
  end

  test "transactions flip sign and link their category, merchant and tags" do
    transaction = records("Transaction")["monarch-transaction:1"]

    assert_equal "10.00", transaction["amount"]
    assert_equal "monarch-category:Groceries", transaction["category_id"]
    assert_equal "monarch-merchant:Grocer", transaction["merchant_id"]
    assert_equal [ "monarch-tag:Food" ], transaction["tag_ids"]
  end

  test "transfers and card payments become transaction kinds without a category" do
    payment = records("Transaction")["monarch-transaction:4"]

    assert_equal "cc_payment", payment["kind"]
    assert_nil payment["category_id"]
  end

  test "pending transactions are left out" do
    assert_not records("Transaction").key?("monarch-transaction:5")
  end

  test "liability balances are positive in Sure" do
    assert_equal "70.00", records("Account")["monarch-account:Card"]["balance"]
  end

  test "new accounts open with the first Monarch balance" do
    opening = records("Valuation")["monarch-valuation:Checking:2024-01-01"]

    assert_equal [ "opening_anchor", "100.00" ], opening.values_at("kind", "amount")
    assert records("Account")["monarch-account:Checking"]["skip_opening_balance_import"]
  end

  test "a new account takes the chosen name but keeps Monarch's for matching" do
    account = records("Account", "Checking" => { account_name: "Everyday" })["monarch-account:Checking"]

    assert_equal "Everyday", account["name"]
    assert records("Transaction", "Checking" => { account_name: "Everyday" }).values.any? { |t| t["account_id"] == "monarch-account:Checking" }
  end

  test "closed accounts drop to zero and are disabled" do
    valuations = records("Valuation", "Old Savings" => { closed: true })

    assert_equal "0.00", valuations["monarch-valuation:Old Savings:2024-01-02"]["amount"]
    assert_equal "disabled", records("Account", "Old Savings" => { closed: true })["monarch-account:Old Savings"]["status"]
  end

  test "skipped accounts and their transactions are left out" do
    result = convert("Card" => { include: false })

    assert_not record_ids(result, "Account").include?("monarch-account:Card")
    assert_equal 1, result.stats["transactions_skipped_excluded_account"]
  end

  test "balances-only accounts keep their history without transactions" do
    result = convert("Checking" => { transactions: false })
    checking = result.records.select { |r| r["type"] == "Valuation" && r["data"]["account_id"] == "monarch-account:Checking" }

    assert_equal %w[100.00 90.00 95.00], checking.map { |r| r["data"]["amount"] }
    assert_equal 3, result.stats["transactions_skipped_balances_only"]
  end

  test "a changed current balance adds a valuation today" do
    valuations = records("Valuation", { "Checking" => { current_balance: BigDecimal("120") }, "Card" => { current_balance: BigDecimal("80") } },
      today: Date.new(2024, 1, 10))

    assert_equal "120.00", valuations["monarch-valuation:Checking:2024-01-10"]["amount"]
    assert_equal "80.00", valuations["monarch-valuation:Card:2024-01-10"]["amount"]
  end

  test "accounts whose balance ignores transactions get a valuation for every change" do
    result = convert("Checking" => { type: "Property" })
    checking = result.records.select { |r| r["type"] == "Valuation" && r["data"]["account_id"] == "monarch-account:Checking" }

    assert_equal %w[100.00 90.00 95.00], checking.map { |r| r["data"]["amount"] }
    assert record_ids(result, "Transaction").include?("monarch-transaction:1")
  end

  test "existing entries count in the account's currency, without split parents" do
    account = existing_account(opening_date: Date.new(2023, 12, 1), opening_balance: 100)
    ExchangeRate.create!(date: Date.new(2024, 1, 2), from_currency: "EUR", to_currency: "USD", rate: 1.1)
    account.entries.create!(date: Date.new(2024, 1, 2), amount: 10, currency: "EUR", name: "Paris", entryable: Transaction.new)
    parent = account.entries.create!(date: Date.new(2024, 1, 2), amount: 4, currency: "USD", name: "Shop", entryable: Transaction.new)
    parent.split!([ { name: "One", amount: 1, category_id: nil }, { name: "Two", amount: 3, category_id: nil } ])
    exports = MonarchImport::Exports.new(balances_csv: "Date,Balance,Account\n2024-01-01,100.00,Checking\n2024-01-02,85.00,Checking\n")
    choice = MonarchImport::Converter::Choice.new(name: "Checking", type: "Depository", closed: false, include: true,
      transactions: true, current_balance: nil, target: account)

    result = MonarchImport::Converter.new(exports: exports, choices: [ choice ], family: @family, today: Date.new(2024, 1, 4)).result
    assert_empty record_ids(result, "Valuation")
  end

  test "existing categories and merchants keep their look" do
    @family.categories.create!(name: "Groceries", color: "#123456", lucide_icon: "carrot", classification_unused: "expense")
    @family.merchants.create!(name: "Grocer", color: "#abcdef")
    result = convert

    category = result.records.find { |r| r["type"] == "Category" && r["data"]["name"] == "Groceries" }["data"]
    merchant = result.records.find { |r| r["type"] == "Merchant" && r["data"]["name"] == "Grocer" }["data"]
    assert_equal [ "#123456", "carrot" ], category.values_at("color", "lucide_icon")
    assert_equal "#abcdef", merchant["color"]
    assert_equal 1, result.stats["categories_reusing_existing"]
  end

  test "importing into an existing account moves its opening balance to the start of the history" do
    account = existing_account(opening_date: Date.new(2024, 1, 3), opening_balance: 500)
    result = convert("Checking" => { target: account })

    assert_not record_ids(result, "Account").include?("monarch-account:Checking")
    move = result.opening_balance_moves.sole
    assert_equal [ Date.new(2024, 1, 1), BigDecimal("100") ], [ move.date, move.balance ]
    assert_not record_ids(result, "Valuation").include?("monarch-valuation:Checking:2024-01-01")
  end

  test "an earlier opening balance stays, and disagreeing balance updates are reported" do
    account = existing_account(opening_date: Date.new(2023, 12, 1), opening_balance: 100)
    account.entries.create!(date: Date.new(2024, 1, 2), amount: 70, currency: "USD", name: "Manual", entryable: Valuation.new(kind: "reconciliation"))
    result = convert("Checking" => { target: account })

    assert_empty result.opening_balance_moves
    assert_equal [ Date.new(2024, 1, 2) ], result.conflicts["Checking"]
  end

  test "transactions keep their Monarch ID outside external_id, and are import locked" do
    transaction = records("Transaction")["monarch-transaction:1"]

    assert_equal({ "monarch" => { "transaction_id" => "1" } }, transaction["extra"])
    assert transaction["import_locked"]
    assert_not transaction.key?("external_id")
  end

  test "transactions already imported from Monarch are skipped" do
    account = existing_account(opening_date: Date.new(2023, 12, 1), opening_balance: 100)
    account.entries.create!(date: Date.new(2024, 1, 2), amount: 10, currency: "USD", name: "Grocer",
      external_id: "sfin-1", source: "simplefin", entryable: Transaction.new(extra: { "monarch" => { "transaction_id" => "1" } }))
    result = convert("Checking" => { target: account })

    assert_not record_ids(result, "Transaction").include?("monarch-transaction:1")
    assert_equal 1, result.stats["transactions_skipped_already_in_sure"]
    assert_equal 0, result.overlapping_transactions["Checking"]
  end

  test "transactions imported earlier through the Monarch to Sure tool are recognised" do
    account = existing_account(opening_date: Date.new(2023, 12, 1), opening_balance: 100)
    account.entries.create!(date: Date.new(2024, 1, 2), amount: 10, currency: "USD", name: "Grocer",
      source: "sure_import_session:abc", external_id: "Transaction:monarch-transaction:1", entryable: Transaction.new)

    assert_equal 1, convert("Checking" => { target: account }).stats["transactions_skipped_already_in_sure"]
  end

  test "a tool-style external ID from another source is not taken as a Monarch import" do
    account = existing_account(opening_date: Date.new(2023, 12, 1), opening_balance: 100)
    account.entries.create!(date: Date.new(2024, 1, 3), amount: 25, currency: "USD", name: "Other",
      source: "some_api_client", external_id: "Transaction:monarch-transaction:1", entryable: Transaction.new)
    result = convert("Checking" => { target: account })

    assert record_ids(result, "Transaction").include?("monarch-transaction:1")
    assert_equal 1, result.overlapping_transactions["Checking"]
  end

  test "a source that only resembles the tool's isn't taken as one" do
    account = existing_account(opening_date: Date.new(2023, 12, 1), opening_balance: 100)
    account.entries.create!(date: Date.new(2024, 1, 3), amount: 25, currency: "USD", name: "Other",
      source: "sure-import-session-abc", external_id: "Transaction:monarch-transaction:1", entryable: Transaction.new)

    assert record_ids(convert("Checking" => { target: account }), "Transaction").include?("monarch-transaction:1")
  end

  test "an entry matched by Monarch ID isn't matched again by date and amount" do
    account = existing_account(opening_date: Date.new(2023, 12, 1), opening_balance: 100)
    account.entries.create!(date: Date.new(2024, 1, 2), amount: 10, currency: "USD", name: "Grocer",
      entryable: Transaction.new(extra: { "monarch" => { "transaction_id" => "1" } }))
    @exports = MonarchImport::Exports.new(
      balances_csv: file_fixture("imports/monarch_balances.csv").read,
      transactions_csv: file_fixture("imports/monarch_transactions.csv").read +
        "2024-01-02,Grocer,Groceries,Checking,GROCER #12,,-10.00,,Me,false,,,false,6\n"
    )
    result = convert("Checking" => { target: account })

    assert_not record_ids(result, "Transaction").include?("monarch-transaction:1")
    assert record_ids(result, "Transaction").include?("monarch-transaction:6")
  end

  test "a new account's balance is today's, with later valuations still imported" do
    @exports = MonarchImport::Exports.new(balances_csv: "Date,Balance,Account\n2024-01-01,100.00,Checking\n2024-01-10,200.00,Checking\n")
    result = convert(today: Date.new(2024, 1, 4))

    assert_equal "100.00", records_of(result, "Account")["monarch-account:Checking"]["balance"]
    assert records_of(result, "Valuation").key?("monarch-valuation:Checking:2024-01-10")
  end

  test "transactions from the Monarch to Sure tool don't count as unmatched" do
    account = existing_account(opening_date: Date.new(2023, 12, 1), opening_balance: 100)
    account.entries.create!(date: Date.new(2024, 1, 3), amount: 25, currency: "USD", name: "Older export",
      source: "sure_import_session:abc", external_id: "Transaction:monarch-transaction:99", entryable: Transaction.new)

    assert_equal 0, convert("Checking" => { target: account }).overlapping_transactions["Checking"]
  end

  test "Sure's matcher skips a transaction already entered by hand, once" do
    account = existing_account(opening_date: Date.new(2023, 12, 1), opening_balance: 100)
    account.entries.create!(date: Date.new(2024, 1, 2), amount: 10, currency: "USD", name: "Groceries", entryable: Transaction.new)
    exports = MonarchImport::Exports.new(
      balances_csv: file_fixture("imports/monarch_balances.csv").read,
      transactions_csv: file_fixture("imports/monarch_transactions.csv").read +
        "2024-01-02,Grocer,Groceries,Checking,GROCER #12,,-10.00,,Me,false,,,false,6\n"
    )
    choices = exports.suggestions.map do |s|
      MonarchImport::Converter::Choice.new(name: s.name, type: s.type, closed: false, include: true, transactions: true,
        current_balance: nil, target: (account if s.name == "Checking"))
    end
    result = MonarchImport::Converter.new(exports: exports, choices: choices, family: @family, today: Date.new(2024, 1, 4)).result

    assert_equal 1, result.stats["transactions_skipped_already_in_sure"]
    assert_equal 1, record_ids(result, "Transaction").count { |id| id.in?(%w[monarch-transaction:1 monarch-transaction:6]) }
  end

  test "existing transactions in the same period that match nothing are counted" do
    account = existing_account(opening_date: Date.new(2023, 12, 1), opening_balance: 100)
    account.entries.create!(date: Date.new(2024, 1, 2), amount: 7, currency: "USD", name: "Bakery", entryable: Transaction.new)

    assert_equal 1, convert("Checking" => { target: account }).overlapping_transactions["Checking"]
  end

  private
    def choices(overrides = {})
      @exports.suggestions.map do |suggestion|
        MonarchImport::Converter::Choice.new(
          name: suggestion.name, type: suggestion.type, closed: false, include: true, transactions: true,
          current_balance: nil, target: nil, **overrides.fetch(suggestion.name, {})
        )
      end
    end

    def convert(overrides = {}, today: Date.new(2024, 1, 4), **by_name)
      MonarchImport::Converter.new(exports: @exports, choices: choices(overrides.merge(by_name)), family: @family, today: today).result
    end

    def records(type, overrides = {}, **options)
      convert(overrides, **options).records.select { |r| r["type"] == type }.to_h { |r| [ r["data"]["id"], r["data"] ] }
    end

    def records_of(result, type)
      result.records.select { |r| r["type"] == type }.to_h { |r| [ r["data"]["id"], r["data"] ] }
    end

    def record_ids(result, type)
      result.records.select { |r| r["type"] == type }.map { |r| r["data"]["id"] }
    end

    def existing_account(opening_date:, opening_balance:)
      account = @family.accounts.create!(name: "Sure Checking", balance: opening_balance, currency: "USD", accountable: Depository.new)
      account.entries.create!(date: opening_date, amount: opening_balance, currency: "USD", name: "Opening balance",
        entryable: Valuation.new(kind: "opening_anchor"))
      account
    end
end
