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

  # ---------------------------------------------------------------------------
  # Validation: refund requires a negative amount
  # ---------------------------------------------------------------------------

  test "a refund with a negative amount is valid" do
    entry = create_transaction(account: @checking_account, amount: -50, refund: true, category: @groceries)
    assert entry.persisted?
  end

  test "a refund with a positive amount is invalid on create" do
    entry = Entry.new(
      account: @checking_account, name: "Bad refund", date: Date.current, currency: "USD", amount: 50,
      entryable: Transaction.new(refund: true, category: @groceries)
    )

    assert_not entry.valid?
    assert_includes entry.errors[:amount], "must be negative for a refund"
  end

  test "toggling refund on an existing positive-amount transaction is invalid" do
    entry = create_transaction(account: @checking_account, amount: 50, category: @groceries)

    entry.entryable.refund = true
    assert_not entry.entryable.valid?
    assert_includes entry.entryable.errors[:refund], "requires a negative transaction amount"
  end

  test "non-refund transactions are unaffected by the refund-amount validation regardless of sign" do
    positive = create_transaction(account: @checking_account, amount: 100)
    negative = create_transaction(account: @checking_account, amount: -100)

    assert positive.persisted?
    assert negative.persisted?
  end

  test "splitting a refund preserves the refund classification on each child" do
    entry = create_transaction(account: @checking_account, amount: -50, refund: true, category: @groceries)

    children = entry.split!([
      { name: "Refund item one", amount: -20, category_id: @groceries.id },
      { name: "Refund item two", amount: -30, category_id: @groceries.id }
    ])

    assert children.all? { |child| child.transaction.refund? }
    assert children.all? { |child| child.classification == "expense" }
  end

  test "changing refund touches the entry to invalidate family entry caches" do
    entry = create_transaction(account: @checking_account, amount: -50, category: @groceries)
    family = @checking_account.family
    family.entries.where.not(id: entry.id).update_all(updated_at: 2.days.ago)
    entry.update_columns(updated_at: 1.day.ago)
    cache_version = family.reload.entries_cache_version

    entry.transaction.update!(refund: true)

    assert_operator entry.reload.updated_at, :>, 1.minute.ago
    assert_not_equal cache_version, family.reload.entries_cache_version
  end
end
