require "test_helper"

class TransactionsControllerTest < ActionDispatch::IntegrationTest
  include EntryableResourceInterfaceTest, EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:transaction)
  end

  test "new renders custom description suggestions UI without datalist" do
    get new_transaction_url(account_id: @entry.account_id)

    assert_response :success
    assert_dom "[data-controller='transaction-name-suggestions']", count: 1
    assert_dom "#transaction-name-suggestions-listbox", count: 1
    assert_dom "datalist#transaction-name-suggestions", count: 0
  end

  test "name_suggestions returns case-insensitive deduped names" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new

    create_transaction(account: account, name: "Sample Vendor")
    create_transaction(account: account, name: "sample vendor")
    create_transaction(account: account, name: "Sample Vendor")

    get name_suggestions_transactions_url(query: "sample"), as: :json

    assert_response :success
    suggestions = response.parsed_body["suggestions"]
    assert_equal 1, suggestions.count { |name| name.downcase == "sample vendor" }
  end

  test "name_suggestions prioritizes exact then prefix matches" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new

    create_transaction(account: account, name: "Cost")
    create_transaction(account: account, name: "Cost Center")
    create_transaction(account: account, name: "Warehouse Cost")

    get name_suggestions_transactions_url(query: "cost"), as: :json

    assert_response :success
    suggestions = response.parsed_body["suggestions"]
    assert_equal [ "Cost", "Cost Center", "Warehouse Cost" ], suggestions.first(3)
  end

  test "name_suggestions keeps older exact matches ahead of many newer substring matches" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new

    create_transaction(account: account, name: "Cost")

    501.times do |index|
      create_transaction(account: account, name: "Miscost Example #{index}")
    end

    get name_suggestions_transactions_url(query: "cost"), as: :json

    assert_response :success
    suggestions = response.parsed_body["suggestions"]
    assert_equal "Cost", suggestions.first
  end

  test "name_suggestions returns empty for very short queries" do
    get name_suggestions_transactions_url(query: "c"), as: :json

    assert_response :success
    assert_equal [], response.parsed_body["suggestions"]
  end

  test "create failure rerenders new form with custom suggestions UI" do
    post transactions_url, params: {
      entry: {
        account_id: @entry.account_id,
        name: "",
        date: Date.current,
        currency: "USD",
        amount: 100,
        nature: "outflow",
        entryable_type: @entry.entryable_type
      }
    }

    assert_response :unprocessable_entity
    assert_dom "[data-controller='transaction-name-suggestions']", count: 1
    assert_dom "#transaction-name-suggestions-listbox", count: 1
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

  test "split parent rows mark amount as privacy-sensitive" do
    entry = create_transaction(account: accounts(:depository), amount: 100, name: "Split parent")

    entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    get transactions_url

    assert_response :success
    assert_select ".split-group > div.opacity-50 p.privacy-sensitive", count: 1
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
      income_money: Money.new(0, "USD"),
      transfer_inflow_money: Money.new(0, "USD"),
      transfer_outflow_money: Money.new(0, "USD")
    )

    Transaction::Search.expects(:new).with(family, filters: {}, accessible_account_ids: [ account.id ]).returns(search)
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
      income_money: Money.new(0, "USD"),
      transfer_inflow_money: Money.new(0, "USD"),
      transfer_outflow_money: Money.new(0, "USD")
    )

    Transaction::Search.expects(:new).with(family, filters: { "categories" => [ "Food" ], "types" => [ "expense" ] }, accessible_account_ids: [ account.id ]).returns(search)
    search.expects(:totals).once.returns(totals)

    get transactions_url(q: { categories: [ "Food" ], types: [ "expense" ] })
    assert_response :success
  end

  test "shows inflow/outflow labels when filtering by transfers only" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new

    create_transaction(account: account, amount: 100)

    search = Transaction::Search.new(family, filters: { "types" => [ "transfer" ] })
    totals = OpenStruct.new(
      count: 2,
      expense_money: Money.new(0, "USD"),
      income_money: Money.new(0, "USD"),
      transfer_inflow_money: Money.new(5000, "USD"),
      transfer_outflow_money: Money.new(3000, "USD")
    )

    Transaction::Search.expects(:new).with(family, filters: { "types" => [ "transfer" ] }, accessible_account_ids: [ account.id ]).returns(search)
    search.expects(:totals).once.returns(totals)

    get transactions_url(q: { types: [ "transfer" ] })
    assert_response :success
    assert_select "#total-income", text: totals.transfer_inflow_money.format
    assert_select "#total-expense", text: totals.transfer_outflow_money.format
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
      account: account,
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

  test "new with duplicate_entry_id pre-fills form from source transaction" do
    @entry.reload

    get new_transaction_url(duplicate_entry_id: @entry.id)
    assert_response :success
    assert_select "input[name='entry[name]'][value=?]", @entry.name
    assert_select "input[type='number'][name='entry[amount]']" do |elements|
      assert_equal sprintf("%.2f", @entry.amount.abs), elements.first["value"]
    end
    assert_select "input[type='hidden'][name='entry[entryable_attributes][merchant_id]']"
  end

  test "new with invalid duplicate_entry_id renders empty form" do
    get new_transaction_url(duplicate_entry_id: -1)
    assert_response :success
    assert_select "input[name='entry[name]']" do |elements|
      assert_nil elements.first["value"]
    end
  end

  test "new with duplicate_entry_id from another family does not prefill form" do
    other_family = families(:empty)
    other_account = other_family.accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
    other_entry = create_transaction(account: other_account, name: "Should not leak", amount: 50)

    get new_transaction_url(duplicate_entry_id: other_entry.id)
    assert_response :success
    assert_select "input[name='entry[name]']" do |elements|
      assert_nil elements.first["value"]
    end
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

  test "exchange_rate endpoint returns rate for different currencies" do
    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "EUR", to: "USD", date: Date.current)
                .returns(1.2)

    get exchange_rate_url, params: {
      from: "EUR",
      to: "USD",
      date: Date.current
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 1.2, json_response["rate"]
  end

  test "exchange_rate endpoint returns same_currency for matching currencies" do
    get exchange_rate_url, params: {
      from: "USD",
      to: "USD"
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert json_response["same_currency"]
    assert_equal 1.0, json_response["rate"]
  end

  test "exchange_rate endpoint uses provided date" do
    custom_date = 3.days.ago.to_date
    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "EUR", to: "USD", date: custom_date)
                .returns(1.25)

    get exchange_rate_url, params: {
      from: "EUR",
      to: "USD",
      date: custom_date
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 1.25, json_response["rate"]
  end

  test "exchange_rate endpoint returns 400 when from currency is missing" do
    get exchange_rate_url, params: {
      to: "USD"
    }

    assert_response :bad_request
    json_response = JSON.parse(response.body)
    assert_equal "from and to currencies are required", json_response["error"]
  end

  test "exchange_rate endpoint returns 400 when to currency is missing" do
    get exchange_rate_url, params: {
      from: "EUR"
    }

    assert_response :bad_request
    json_response = JSON.parse(response.body)
    assert_equal "from and to currencies are required", json_response["error"]
  end

  test "exchange_rate endpoint returns 400 on invalid date format" do
    get exchange_rate_url, params: {
      from: "EUR",
      to: "USD",
      date: "not-a-date"
    }

    assert_response :bad_request
    json_response = JSON.parse(response.body)
    assert_equal "Invalid date format", json_response["error"]
  end

  test "exchange_rate endpoint returns 404 when rate not found" do
    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "EUR", to: "USD", date: Date.current)
                .returns(nil)

    get exchange_rate_url, params: {
      from: "EUR",
      to: "USD"
    }

    assert_response :not_found
    json_response = JSON.parse(response.body)
    assert_equal "Exchange rate not found", json_response["error"]
  end

  test "creates transaction with custom exchange rate" do
    account = @user.family.accounts.create!(
      name: "USD Account",
      currency: "USD",
      balance: 1000,
      accountable: Depository.new
    )

    assert_difference [ "Entry.count", "Transaction.count" ], 1 do
      post transactions_url, params: {
        entry: {
          account_id: account.id,
          name: "EUR transaction with custom rate",
          date: Date.current,
          currency: "EUR",
          amount: 100,
          nature: "outflow",
          entryable_type: "Transaction",
          entryable_attributes: {
            category_id: Category.first.id,
            exchange_rate: "1.5"
          }
        }
      }
    end

    created_entry = Entry.order(:created_at).last
    assert_equal "EUR", created_entry.currency
    assert_equal 100, created_entry.amount
    assert_equal 1.5, created_entry.transaction.extra["exchange_rate"]
  end

  test "creates transaction without custom exchange rate" do
    account = @user.family.accounts.create!(
      name: "USD Account",
      currency: "USD",
      balance: 1000,
      accountable: Depository.new
    )

    assert_difference [ "Entry.count", "Transaction.count" ], 1 do
      post transactions_url, params: {
        entry: {
          account_id: account.id,
          name: "EUR transaction without custom rate",
          date: Date.current,
          currency: "EUR",
          amount: 100,
          nature: "outflow",
          entryable_type: "Transaction",
          entryable_attributes: {
            category_id: Category.first.id
          }
        }
      }
    end

    created_entry = Entry.order(:created_at).last
    assert_nil created_entry.transaction.extra["exchange_rate"]
  end
end
