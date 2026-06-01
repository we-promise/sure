require "test_helper"

class Transaction::RefundTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @checking_account = @family.accounts.create!(
      name: "Checking", currency: @family.currency, balance: 5000, accountable: Depository.new
    )
    @groceries = @family.categories.create!(name: "Groceries")
  end

  # ---------------------------------------------------------------------------
  # Enum / predicate
  # ---------------------------------------------------------------------------

  test "refund? returns true for refund kind" do
    entry = create_transaction(account: @checking_account, amount: -50, kind: "refund", category: @groceries)
    assert entry.entryable.refund?
  end

  test "refund? returns false for standard kind" do
    entry = create_transaction(account: @checking_account, amount: -50)
    assert_not entry.entryable.refund?
  end

  test "refund kind is not in BUDGET_EXCLUDED_KINDS" do
    assert_not_includes Transaction::BUDGET_EXCLUDED_KINDS, "refund",
      "refund must appear in analytics to offset expense totals"
  end

  test "refund kind is not in TRANSFER_KINDS" do
    assert_not_includes Transaction::TRANSFER_KINDS, "refund"
  end

  # ---------------------------------------------------------------------------
  # Optional back-reference association
  # ---------------------------------------------------------------------------

  test "refund can be linked to an original transaction" do
    original_entry = create_transaction(account: @checking_account, amount: 200, category: @groceries)
    original_txn    = original_entry.entryable

    refund_entry = create_transaction(
      account: @checking_account, amount: -50, kind: "refund", category: @groceries
    )
    refund_txn = refund_entry.entryable
    refund_txn.update!(refund_of_transaction: original_txn)

    assert_equal original_txn, refund_txn.reload.refund_of_transaction
  end

  test "refund_of_transaction_id is optional — refund can exist without a link" do
    entry = create_transaction(account: @checking_account, amount: -30, kind: "refund", category: @groceries)
    assert_nil entry.entryable.refund_of_transaction_id
    assert entry.entryable.valid?
  end

  # ---------------------------------------------------------------------------
  # Entry#classification
  # ---------------------------------------------------------------------------

  test "Entry#classification returns 'expense' for a refund even though amount is negative" do
    entry = create_transaction(account: @checking_account, amount: -50, kind: "refund", category: @groceries)
    assert_equal "expense", entry.classification
  end

  test "Entry#classification still returns 'income' for a plain negative-amount transaction" do
    entry = create_transaction(account: @checking_account, amount: -100)
    assert_equal "income", entry.classification
  end

  test "Entry#classification returns 'expense' for a positive-amount transaction" do
    entry = create_transaction(account: @checking_account, amount: 100)
    assert_equal "expense", entry.classification
  end
end
