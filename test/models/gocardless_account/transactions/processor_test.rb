require "test_helper"

# These cover the mappings that fail SILENTLY if they are wrong: a flipped sign still
# imports cleanly and just turns every expense into income, and a mis-picked balance
# still shows a plausible number that quietly disagrees with the bank's own app.
class GocardlessAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  setup do
    @processor = GocardlessAccount::Transactions::Processor.allocate
  end

  test "negates GoCardless sign convention so money out is positive" do
    debit = transaction_data(amount: "-12.34")

    assert_equal BigDecimal("12.34"), @processor.send(:parse_transaction_amount, debit)
  end

  test "negates credits so money in is negative" do
    credit = transaction_data(amount: "500.00")

    assert_equal BigDecimal("-500.00"), @processor.send(:parse_transaction_amount, credit)
  end

  test "returns nil when amount is missing rather than importing a zero" do
    assert_nil @processor.send(:parse_transaction_amount, {}.with_indifferent_access)
  end

  test "prefers unstructured remittance info for the name and squishes whitespace" do
    data = transaction_data.merge(
      "remittanceInformationUnstructured" => "  TESCO   STORES 3421 ",
      "creditorName" => "IGNORED"
    ).with_indifferent_access

    assert_equal "TESCO STORES 3421", @processor.send(:transaction_name, data)
  end

  test "falls back to counterparty name when remittance info is absent" do
    data = transaction_data.merge("creditorName" => "NATWEST").with_indifferent_access

    assert_equal "NATWEST", @processor.send(:transaction_name, data)
  end

  test "joins the array form of remittance info" do
    data = transaction_data.merge(
      "remittanceInformationUnstructuredArray" => [ "CARD PAYMENT TO", "SAINSBURYS" ]
    ).with_indifferent_access

    assert_equal "CARD PAYMENT TO SAINSBURYS", @processor.send(:transaction_name, data)
  end

  test "uses the bank transaction id when present" do
    data = transaction_data.merge("transactionId" => "abc123").with_indifferent_access

    assert_equal "abc123", @processor.send(:external_id_for, data)
  end

  test "derives a stable surrogate id for pending entries with no transaction id" do
    data = transaction_data.merge("bookingDate" => "2026-08-15").with_indifferent_access

    first = @processor.send(:external_id_for, data)
    second = @processor.send(:external_id_for, data.deep_dup)

    assert first.start_with?("pending:"), "expected a pending-prefixed surrogate id"
    assert_equal first, second, "surrogate id must be deterministic or every sync duplicates"
  end

  test "surrogate ids differ when the amount differs" do
    a = transaction_data(amount: "-1.00").merge("bookingDate" => "2026-08-15").with_indifferent_access
    b = transaction_data(amount: "-2.00").merge("bookingDate" => "2026-08-15").with_indifferent_access

    assert_not_equal @processor.send(:external_id_for, a), @processor.send(:external_id_for, b)
  end

  private

    def transaction_data(amount: "-10.00")
      {
        "transactionAmount" => { "amount" => amount, "currency" => "GBP" }
      }.with_indifferent_access
    end
end
