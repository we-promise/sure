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
  # Boolean flag / predicate
  # ---------------------------------------------------------------------------

  test "refund? returns true when refund flag is set" do
    entry = create_transaction(account: @checking_account, amount: -50, refund: true, category: @groceries)
    assert entry.entryable.refund?
  end

  test "refund? returns false by default" do
    entry = create_transaction(account: @checking_account, amount: -50)
    assert_not entry.entryable.refund?
  end

  # ---------------------------------------------------------------------------
  # Entry#classification
  # ---------------------------------------------------------------------------

  test "Entry#classification returns 'expense' for a refund even though amount is negative" do
    entry = create_transaction(account: @checking_account, amount: -50, refund: true, category: @groceries)
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
