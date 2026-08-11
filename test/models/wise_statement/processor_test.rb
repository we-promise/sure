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
