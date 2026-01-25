require "test_helper"

class TransactionsControllerTest < ActionDispatch::IntegrationTest
  include EntryableResourceInterfaceTest, EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:transaction)
  end

  test "creates with transaction details" do
    assert_difference [ "Entry.count", "Transaction.count" ], 1 do
      post transactions_url, params: {
        entry: {
          account_id: @entry.account_id,
          name: "New transaction",
          date: Date.current,
          currency: "USD",
          amount: 100,
          nature: "inflow",
          entryable_type: @entry.entryable_type,
          entryable_attributes: {
            tag_ids: [ Tag.first.id, Tag.second.id ],
            category_id: Category.first.id,
            merchant_id: Merchant.first.id
          }
        }
      }
    end

    created_entry = Entry.order(:created_at).last

    assert_redirected_to account_url(created_entry.account)
    assert_equal "Transaction created", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "updates with transaction details" do
    assert_no_difference [ "Entry.count", "Transaction.count" ] do
      patch transaction_url(@entry), params: {
        entry: {
          name: "Updated name",
          date: Date.current,
          currency: "USD",
          amount: 100,
          nature: "inflow",
          entryable_type: @entry.entryable_type,
          notes: "test notes",
          excluded: false,
          entryable_attributes: {
            id: @entry.entryable_id,
            tag_ids: [ Tag.first.id, Tag.second.id ],
            category_id: Category.first.id,
            merchant_id: Merchant.first.id
          }
        }
      }
    end

    @entry.reload

    assert_equal "Updated name", @entry.name
    assert_equal Date.current, @entry.date
    assert_equal "USD", @entry.currency
    assert_equal -100, @entry.amount
    assert_equal [ Tag.first.id, Tag.second.id ], @entry.entryable.tag_ids.sort
    assert_equal Category.first.id, @entry.entryable.category_id
    assert_equal Merchant.first.id, @entry.entryable.merchant_id
    assert_equal "test notes", @entry.notes
    assert_equal false, @entry.excluded

    assert_equal "Transaction updated", flash[:notice]
    assert_redirected_to account_url(@entry.account)
    assert_enqueued_with(job: SyncJob)
  end

  test "transaction count represents filtered total" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new

    3.times do
      create_transaction(account: account)
    end

    get transactions_url(per_page: 10)

    assert_dom "#total-transactions", count: 1, text: family.entries.transactions.size.to_s

    searchable_transaction = create_transaction(account: account, name: "Unique test name")

    get transactions_url(q: { search: searchable_transaction.name })

    # Only finds 1 transaction that matches filter
    assert_dom "#" + dom_id(searchable_transaction), count: 1
    assert_dom "#total-transactions", count: 1, text: "1"
  end

  test "can paginate" do
  family = families(:empty)
  sign_in users(:empty)

  # Clean up any existing entries to ensure clean test
  family.accounts.each { |account| account.entries.delete_all }

  account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new

  # Create multiple transactions for pagination
  25.times do |i|
    create_transaction(
      account: account,
      name: "Transaction #{i + 1}",
      amount: 100 + i,  # Different amounts to prevent transfer matching
      date: Date.current - i.days  # Different dates
    )
  end

  total_transactions = family.entries.transactions.count
  assert_operator total_transactions, :>=, 20, "Should have at least 20 transactions for testing"

  # Test page 1 - should show limited transactions
  get transactions_url(page: 1, per_page: 10)
  assert_response :success

  page_1_count = css_select("turbo-frame[id^='entry_']").count
  assert_equal 10, page_1_count, "Page 1 should respect per_page limit"

  # Test page 2 - should show different transactions
  get transactions_url(page: 2, per_page: 10)
  assert_response :success

  page_2_count = css_select("turbo-frame[id^='entry_']").count
  assert_operator page_2_count, :>, 0, "Page 2 should show some transactions"
  assert_operator page_2_count, :<=, 10, "Page 2 should not exceed per_page limit"

  # Test Pagy overflow handling - should redirect or handle gracefully
  get transactions_url(page: 9999999, per_page: 10)

  # Either success (if Pagy shows last page) or redirect (if Pagy redirects)
  assert_includes [ 200, 302 ], response.status, "Pagy should handle overflow gracefully"

  if response.status == 302
    follow_redirect!
    assert_response :success
  end

  overflow_count = css_select("turbo-frame[id^='entry_']").count
  assert_operator overflow_count, :>, 0, "Overflow should show some transactions"
end

  test "calls Transaction::Search totals method with correct search parameters" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new

    create_transaction(account: account, amount: 100)

    search = Transaction::Search.new(family)
    totals = OpenStruct.new(
      count: 1,
      expense_money: Money.new(10000, "USD"),
      income_money: Money.new(0, "USD")
    )

    Transaction::Search.expects(:new).with(family, filters: {}).returns(search)
    search.expects(:totals).once.returns(totals)

    get transactions_url
    assert_response :success
  end

  test "calls Transaction::Search totals method with filtered search parameters" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    category = family.categories.create! name: "Food", color: "#ff0000"

    create_transaction(account: account, amount: 100, category: category)

    search = Transaction::Search.new(family, filters: { "categories" => [ "Food" ], "types" => [ "expense" ] })
    totals = OpenStruct.new(
      count: 1,
      expense_money: Money.new(10000, "USD"),
      income_money: Money.new(0, "USD")
    )

    Transaction::Search.expects(:new).with(family, filters: { "categories" => [ "Food" ], "types" => [ "expense" ] }).returns(search)
    search.expects(:totals).once.returns(totals)

    get transactions_url(q: { categories: [ "Food" ], types: [ "expense" ] })
    assert_response :success
  end

  test "mark_as_recurring creates a manual recurring transaction" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Test Merchant"
    entry = create_transaction(account: account, amount: 100, merchant: merchant)
    transaction = entry.entryable

    assert_difference "family.recurring_transactions.count", 1 do
      post mark_as_recurring_transaction_path(transaction)
    end

    assert_redirected_to transactions_path
    assert_equal "Transaction marked as recurring", flash[:notice]

    recurring = family.recurring_transactions.last
    assert_equal true, recurring.manual, "Expected recurring transaction to be manual"
    assert_equal merchant.id, recurring.merchant_id
    assert_equal entry.currency, recurring.currency
    assert_equal entry.date.day, recurring.expected_day_of_month
  end

  test "mark_as_recurring shows alert if recurring transaction already exists" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Test Merchant"
    entry = create_transaction(account: account, amount: 100, merchant: merchant)
    transaction = entry.entryable

    # Create existing recurring transaction
    family.recurring_transactions.create!(
      merchant: merchant,
      amount: entry.amount,
      currency: entry.currency,
      expected_day_of_month: entry.date.day,
      last_occurrence_date: entry.date,
      next_expected_date: 1.month.from_now,
      status: "active",
      manual: true,
      occurrence_count: 1
    )

    assert_no_difference "RecurringTransaction.count" do
      post mark_as_recurring_transaction_path(transaction)
    end

    assert_redirected_to transactions_path
    assert_equal "A manual recurring transaction already exists for this pattern", flash[:alert]
  end

  test "mark_as_recurring handles validation errors gracefully" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Test Merchant"
    entry = create_transaction(account: account, amount: 100, merchant: merchant)
    transaction = entry.entryable

    # Stub create_from_transaction to raise a validation error
    RecurringTransaction.expects(:create_from_transaction).raises(
      ActiveRecord::RecordInvalid.new(
        RecurringTransaction.new.tap { |rt| rt.errors.add(:base, "Test validation error") }
      )
    )

    assert_no_difference "RecurringTransaction.count" do
      post mark_as_recurring_transaction_path(transaction)
    end

    assert_redirected_to transactions_path
    assert_equal "Failed to create recurring transaction. Please check the transaction details and try again.", flash[:alert]
  end

  test "mark_as_recurring handles unexpected errors gracefully" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Test Merchant"
    entry = create_transaction(account: account, amount: 100, merchant: merchant)
    transaction = entry.entryable

    # Stub create_from_transaction to raise an unexpected error
    RecurringTransaction.expects(:create_from_transaction).raises(StandardError.new("Unexpected error"))

    assert_no_difference "RecurringTransaction.count" do
      post mark_as_recurring_transaction_path(transaction)
    end

    assert_redirected_to transactions_path
    assert_equal "An unexpected error occurred while creating the recurring transaction", flash[:alert]
  end

  test "unlock clears protection flags on user-modified entry" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    entry = create_transaction(account: account, amount: 100)
    transaction = entry.entryable

    # Mark as protected with locked_attributes on both entry and entryable
    entry.update!(user_modified: true, locked_attributes: { "date" => Time.current.iso8601 })
    transaction.update!(locked_attributes: { "category_id" => Time.current.iso8601 })

    assert entry.reload.protected_from_sync?

    post unlock_transaction_path(transaction)

    assert_redirected_to transactions_path
    assert_equal "Entry unlocked. It may be updated on next sync.", flash[:notice]

    entry.reload
    assert_not entry.user_modified?
    assert_empty entry.locked_attributes, "Entry locked_attributes should be cleared"
    assert_empty entry.entryable.locked_attributes, "Transaction locked_attributes should be cleared"
    assert_not entry.protected_from_sync?
  end

  test "unlock clears import_locked flag" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    entry = create_transaction(account: account, amount: 100)
    transaction = entry.entryable

    # Mark as import locked
    entry.update!(import_locked: true)

    assert entry.reload.protected_from_sync?

    post unlock_transaction_path(transaction)

    assert_redirected_to transactions_path
    entry.reload
    assert_not entry.import_locked?
    assert_not entry.protected_from_sync?
  end
end
