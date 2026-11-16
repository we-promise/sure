require "test_helper"

class WiseStatement::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(
      family: @family,
      name: "Test Wise",
      token: "test_token",
      profile_id: "123",
      profile_type: :business
    )
    @wise_account = WiseAccount.create!(
      wise_item: @wise_item,
      balance_id: "10000001",
      name: "Wise EUR",
      currency: "EUR",
      raw_payload: { "type" => "STANDARD" }
    )
    @account = Account.create!(
      family: @family,
      name: "Wise EUR",
      accountable: Depository.new(subtype: "checking"),
      balance: 0,
      currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @wise_account)
  end

  test "imports signed balance statement amounts and stable reference id" do
    statement = {
      "type" => "CREDIT",
      "date" => "2026-01-15T10:00:00Z",
      "amount" => { "value" => "1200.00", "currency" => "EUR" },
      "details" => { "description" => "Salary" },
      "referenceNumber" => "statement-123"
    }

    entry = WiseStatement::Processor.new(statement, wise_account: @wise_account).process

    assert_equal BigDecimal("-1200.00"), entry.amount
    assert_equal "wise_statement_statement-123", entry.external_id
    assert_equal "Salary", entry.name
    assert_equal "statement-123", entry.entryable.extra.dig("wise", "statement_id")
  end

  test "appends payment reference to the name and excludes fees from the amount" do
    statement = {
      "type" => "DEBIT",
      "date" => "2026-01-15T10:00:00Z",
      "amount" => { "value" => "-7.76", "currency" => "EUR" },
      "totalFees" => { "value" => "0.04", "currency" => "EUR" },
      "details" => {
        "description" => "Sent money to Questrade, Inc.",
        "paymentReference" => "INV-1234"
      },
      "referenceNumber" => "statement-456"
    }

    entry = WiseStatement::Processor.new(statement, wise_account: @wise_account).process

    assert_equal BigDecimal("7.72"), entry.amount
    assert_equal "Sent money to Questrade, Inc. INV-1234", entry.name
    assert_equal "INV-1234", entry.entryable.extra.dig("wise", "payment_reference")
    assert_equal "0.04", entry.entryable.extra.dig("wise", "fee")

    fee_entry = @account.entries.find_by(external_id: "wise_statement_statement-456_fee")
    assert_not_nil fee_entry
    assert_equal BigDecimal("0.04"), fee_entry.amount
    assert_equal I18n.t("wise_items.entries.fee_name"), fee_entry.name
  end

  test "re-importing a statement row drops wise metadata Wise no longer reports" do
    statement = {
      "type" => "DEBIT",
      "date" => "2026-01-15T10:00:00Z",
      "amount" => { "value" => "-7.76", "currency" => "EUR" },
      "details" => { "description" => "Card payment", "paymentReference" => "INV-1234" },
      "referenceNumber" => "statement-457"
    }
    WiseStatement::Processor.new(statement, wise_account: @wise_account).process

    entry = WiseStatement::Processor.new(statement.merge("details" => { "description" => "Card payment" }),
                                         wise_account: @wise_account).process

    assert_nil entry.entryable.reload.extra.dig("wise", "payment_reference")
  end

  # The fee entry's wise namespace is replaced as well.
  test "re-importing a statement row drops wise metadata its fee no longer carries" do
    statement = { "type" => "DEBIT", "date" => "2026-01-15T10:00:00Z", "amount" => { "value" => "-7.76", "currency" => "EUR" },
                  "totalFees" => { "value" => "0.04", "currency" => "EUR" }, "referenceNumber" => "statement-458" }
    WiseStatement::Processor.new(statement, wise_account: @wise_account).process
    fee = @account.entries.find_by!(external_id: "wise_statement_statement-458_fee").entryable
    fee.update_column(:extra, fee.extra.deep_merge("wise" => { "payment_reference" => "INV-1234" }))

    WiseStatement::Processor.new(statement, wise_account: @wise_account).process

    assert_equal({ "statement_id" => "statement-458", "type" => "FEE", "fee" => "0.04" }, fee.reload.extra["wise"])
  end

  # A COMPACT credit's amount is what reached the balance, already net of its
  # fee (runningBalance rises by it), so it books in full and the fee is only
  # kept in extra.
  test "books a credit at its full amount and keeps its fee in extra" do
    statement = { "type" => "CREDIT", "date" => "2026-03-01T10:00:00Z",
                  "amount" => { "value" => 95.86, "currency" => "EUR" },
                  "totalFees" => { "value" => 4.14, "currency" => "EUR" },
                  "details" => { "type" => "DEPOSIT", "description" => "Received money" },
                  "runningBalance" => { "value" => 95.86, "currency" => "EUR" },
                  "referenceNumber" => "DEPOSIT-1" }
    processor = WiseStatement::Processor.new(statement, wise_account: @wise_account)

    entry = processor.process

    assert_equal [ [ "wise_statement_DEPOSIT-1", BigDecimal("-95.86") ] ], @account.entries.where(source: "wise").pluck(:external_id, :amount)
    assert_equal "4.14", entry.entryable.extra.dig("wise", "fee")
    assert_equal [ "wise_statement_DEPOSIT-1" ], processor.expected_external_ids
  end

  # Wise reuses a transfer's reference on its refund; the importer gives the
  # later row its own id (WiseItem::StatementMigration).
  test "books a row under the id the importer gave it" do
    statement = { "type" => "CREDIT", "date" => "2026-03-03T10:00:00Z", "amount" => { "value" => 100, "currency" => "EUR" },
                  "referenceNumber" => "TRANSFER-555", "wise_statement_id" => "TRANSFER-555_CREDIT_20260303" }

    entry = WiseStatement::Processor.new(statement, wise_account: @wise_account).process

    assert_equal "wise_statement_TRANSFER-555_CREDIT_20260303", entry.external_id
    assert_equal "TRANSFER-555_CREDIT_20260303", entry.entryable.extra.dig("wise", "statement_id")
  end

  test "books nothing for a conversion the conversion's own row books" do
    statement = { "type" => "DEBIT", "date" => "2026-03-03T10:00:00Z", "amount" => { "value" => -100, "currency" => "EUR" },
                  "details" => { "type" => "CONVERSION" }, "referenceNumber" => "BALANCE-4001",
                  "wise_superseded_by" => "wise_interbalance_4001_outflow", "wise_supersedes" => { "main" => "wise_transfer_1" } }
    processor = WiseStatement::Processor.new(statement, wise_account: @wise_account)

    assert_equal :skipped, processor.process
    assert_empty processor.expected_external_ids
    assert_empty processor.superseded_external_ids
    assert_empty @account.entries
  end

  # The entries the importer matched to the row (wise_supersedes) move to its
  # ids before it books (WiseAccount::Transactions::Processor).
  test "names the entries it takes over, the fee only when it books one" do
    debit = { "type" => "DEBIT", "date" => "2026-03-01T10:00:00Z", "amount" => { "value" => -102.5, "currency" => "EUR" },
              "totalFees" => { "value" => 2.5, "currency" => "EUR" }, "referenceNumber" => "TRANSFER-101",
              "wise_supersedes" => { "main" => "wise_transfer_101", "fee" => "wise_fee_101" } }
    credit = { "type" => "CREDIT", "date" => "2026-03-01T10:00:00Z", "amount" => { "value" => 500, "currency" => "EUR" },
               "totalFees" => { "value" => 1, "currency" => "EUR" }, "referenceNumber" => "TRANSFER-102",
               "wise_supersedes" => { "main" => "wise_transfer_102", "fee" => "wise_fee_102" } }

    assert_equal({ "wise_transfer_101" => "wise_statement_TRANSFER-101", "wise_fee_101" => "wise_statement_TRANSFER-101_fee" },
                 WiseStatement::Processor.new(debit, wise_account: @wise_account).superseded_external_ids)
    assert_equal({ "wise_transfer_102" => "wise_statement_TRANSFER-102" },
                 WiseStatement::Processor.new(credit, wise_account: @wise_account).superseded_external_ids)
  end

  test "ignores fees denominated in a different currency" do
    statement = {
      "type" => "DEBIT",
      "date" => "2026-01-15T10:00:00Z",
      "amount" => { "value" => "-10.00", "currency" => "EUR" },
      "totalFees" => { "value" => "1.50", "currency" => "GBP" },
      "details" => { "description" => "Card payment" },
      "referenceNumber" => "statement-789"
    }

    entry = WiseStatement::Processor.new(statement, wise_account: @wise_account).process

    assert_equal BigDecimal("10.00"), entry.amount
    assert_equal 1, @account.entries.where(source: "wise").count
  end
end
