require "test_helper"

class TransactionsControllerTest < ActionDispatch::IntegrationTest
  include EntryableResourceInterfaceTest, EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:transaction)
  end

  # Bills has always linked out to transactions. Until now nothing linked back,
  # so a transaction that settled a bill was a dead end. The link-back is part
  # of the preview-gated bills surface, so the viewer needs the flag.
  test "a transaction shows the bill it paid, and links to it" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    series = @user.family.recurring_transactions.create!(
      account: accounts(:depository), name: "Watson Property", amount: 2000,
      currency: "USD", expected_day_of_month: 9, status: "active", manual: true,
      bill_type: "bill", last_occurrence_date: Date.current,
      next_expected_date: Date.current
    )
    series.recurring_occurrences.destroy_all
    due = Date.current.beginning_of_month + 8
    occurrence = series.recurring_occurrences.create!(
      family: @user.family, original_due_on: due, due_on: due,
      currency: "USD", expected_amount: 2000, status: "scheduled"
    )
    RecurringTransaction::Allocator.new(occurrence).allocate!(entry: @entry)

    get transaction_url(@entry), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_match "Watson Property", response.body
    assert_match bill_path(series), response.body, "the bill must be reachable from the transaction"
  end

  test "the bill link-back stays hidden without preview access" do
    series = @user.family.recurring_transactions.create!(
      account: accounts(:depository), name: "Watson Property", amount: 2000,
      currency: "USD", expected_day_of_month: 9, status: "active", manual: true,
      bill_type: "bill", last_occurrence_date: Date.current,
      next_expected_date: Date.current
    )
    series.recurring_occurrences.destroy_all
    due = Date.current.beginning_of_month + 8
    occurrence = series.recurring_occurrences.create!(
      family: @user.family, original_due_on: due, due_on: due,
      currency: "USD", expected_amount: 2000, status: "scheduled"
    )
    RecurringTransaction::Allocator.new(occurrence).allocate!(entry: @entry)

    get transaction_url(@entry), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_no_match bill_path(series), response.body,
      "the preview-gated bill link must not render for a user without the flag"
  end

  test "index groups subcategories immediately after their parent in the category filter" do
    get transactions_url
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    checkbox_values = doc.css("input[name='q[categories][]']").map { |node| node["value"] }

    parent_index = checkbox_values.index(categories(:food_and_drink).name)
    child_index = checkbox_values.index(categories(:subcategory).name)

    assert_not_nil parent_index
    assert_not_nil child_index
    assert_equal parent_index + 1, child_index
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
            tag_ids: [ tags(:one).id, tags(:two).id ],
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

  test "create without an account re-renders the form instead of raising" do
    assert_no_difference [ "Entry.count", "Transaction.count" ] do
      post transactions_url, params: {
        entry: {
          account_id: "",
          name: "New transaction",
          date: Date.current,
          currency: "USD",
          amount: 100,
          nature: "inflow",
          entryable_type: "Transaction",
          entryable_attributes: {
            category_id: Category.first.id
          }
        }
      }
    end

    assert_response :unprocessable_entity
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
            tag_ids: [ tags(:one).id, tags(:two).id ],
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
    assert_equal [ tags(:one).id, tags(:two).id ].sort, @entry.entryable.tag_ids.sort
    assert_equal Category.first.id, @entry.entryable.category_id
    assert_equal Merchant.first.id, @entry.entryable.merchant_id
    assert_equal "test notes", @entry.notes
    assert_equal false, @entry.excluded

    assert_equal "Transaction updated", flash[:notice]
    assert_redirected_to account_url(@entry.account)
    assert_enqueued_with(job: SyncJob)
  end

  test "re-renders show with mark-recurring state when update fails validation" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Test Merchant"
    entry = create_transaction(account: account, amount: 100, merchant: merchant)

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

    patch transaction_url(entry), params: {
      entry: {
        name: "",
        date: entry.date,
        currency: entry.currency,
        amount: entry.amount.abs,
        nature: "outflow",
        entryable_type: entry.entryable_type,
        entryable_attributes: { id: entry.entryable_id }
      }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "A manual recurring transaction already exists for this pattern"
    assert_select "button[disabled]", text: /Mark as Recurring/
  end

  test "turbo_stream update refreshes mark-recurring state when it newly matches" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Test Merchant"
    entry = create_transaction(account: account, amount: 100, name: "Other Name")

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

    patch transaction_url(entry), params: {
      entry: {
        date: entry.date,
        currency: entry.currency,
        amount: entry.amount.abs,
        nature: "outflow",
        entryable_type: entry.entryable_type,
        entryable_attributes: { id: entry.entryable_id, merchant_id: merchant.id }
      }
    }, as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[target='#{dom_id(entry, :mark_recurring)}'] button[disabled]", text: /Mark as Recurring/
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

  test "can update notes on split child transaction" do
    parent = create_transaction(account: accounts(:depository), amount: 100)
    parent.split!([ { name: "Part 1", amount: 60, category_id: nil }, { name: "Part 2", amount: 40, category_id: nil } ])
    child = parent.child_entries.first

    patch transaction_url(child), params: {
      entry: { notes: "split child note", entryable_attributes: { id: child.entryable_id } }
    }

    assert_response :redirect
    assert_equal "split child note", child.reload.notes
  end

  test "can update tags on split child transaction" do
    parent = create_transaction(account: accounts(:depository), amount: 100)
    parent.split!([ { name: "Part 1", amount: 60, category_id: nil }, { name: "Part 2", amount: 40, category_id: nil } ])
    child = parent.child_entries.first
    tag = tags(:one)

    patch transaction_url(child), params: {
      entry: { entryable_attributes: { id: child.entryable_id, tag_ids: [ tag.id ] } }
    }

    assert_response :redirect
    assert_equal [ tag.id ], child.reload.entryable.tag_ids
  end

  test "can update tags through tag-only endpoint" do
    patch tags_transaction_url(@entry, format: :json), params: {
      tag_ids: [ tags(:one).id, tags(:two).id ]
    }

    assert_response :success
    assert_equal [ tags(:one).id, tags(:two).id ].sort, @entry.reload.entryable.tag_ids.sort
    assert_equal @entry.entryable.tag_ids.sort, JSON.parse(response.body)["tag_ids"].sort
  end

  test "tag-only endpoint ignores tags from another family" do
    other_tag = users(:empty).family.tags.create!(name: "Other family")

    patch tags_transaction_url(@entry, format: :json), params: {
      tag_ids: [ tags(:one).id, other_tag.id ]
    }

    assert_response :success
    assert_equal [ tags(:one).id ], @entry.reload.entryable.tag_ids
  end

  test "tag-only endpoint locks tags when clearing all tags" do
    @entry.entryable.update!(tag_ids: [ tags(:one).id ], locked_attributes: {})

    patch tags_transaction_url(@entry, format: :json), params: {
      tag_ids: []
    }, as: :json

    assert_response :success
    assert_empty @entry.reload.entryable.tag_ids
    assert @entry.entryable.locked?(:tag_ids)
  end

  test "tag-only endpoint returns forbidden json for read-only users" do
    sign_in users(:family_member)
    read_only_entry = entries(:transfer_in)
    original_tag_ids = read_only_entry.entryable.tag_ids

    patch tags_transaction_url(read_only_entry), params: {
      tag_ids: [ tags(:one).id ]
    }, headers: {
      "Accept" => "application/json"
    }

    assert_response :forbidden
    assert_equal "application/json", response.media_type
    assert_equal I18n.t("accounts.not_authorized"), JSON.parse(response.body)["error"]
    assert_equal original_tag_ids, read_only_entry.reload.entryable.tag_ids
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

  test "filtered requests without per_page keep the stored page size" do
    family = families(:empty)
    sign_in users(:empty)

    family.accounts.each { |account| account.entries.delete_all }

    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new

    25.times do |i|
      create_transaction(
        account: account,
        name: "Transaction #{i + 1}",
        amount: 100 + i,
        date: Date.current - i.days
      )
    end

    get transactions_url(per_page: 20)
    assert_response :success

    # A filtered request that omits per_page has query params present, so it
    # is not eligible for the "restore stored params" redirect - it must fall
    # back to the previously stored per_page instead of the hardcoded default.
    get transactions_url(q: { search: "Transaction" })
    assert_response :success
    assert_select "select[name='per_page'] option[value='20'][selected]"
    assert_equal 20, css_select("turbo-frame[id^='entry_']").count
  end

  test "pagination does not duplicate or skip transactions with same date and timestamp" do
    family = families(:empty)
    user = users(:empty)
    sign_in user

    family.accounts.each { |account| account.entries.delete_all }

    account = family.accounts.create! name: "Same day", balance: 0, currency: "USD", accountable: Depository.new
    timestamp = Time.zone.parse("2026-05-05 12:00:00")

    entries = 13.times.map do |index|
      create_transaction(
        account: account,
        name: "May 05 Transaction #{index + 1}",
        amount: 100 + index,
        date: Date.new(2026, 5, 5),
        created_at: timestamp,
        updated_at: timestamp
      )
    end

    expected_entry_ids = Entry.where(id: entries.map(&:id)).reverse_chronological.pluck(:id).map(&:to_s)

    get transactions_url(page: 1, per_page: 10)
    assert_response :success
    page_1_entry_ids = rendered_entry_ids

    get transactions_url(page: 2, per_page: 10)
    assert_response :success
    page_2_entry_ids = rendered_entry_ids

    assert_equal expected_entry_ids.first(10), page_1_entry_ids
    assert_equal expected_entry_ids.drop(10), page_2_entry_ids
    assert_empty page_1_entry_ids & page_2_entry_ids
    assert_equal expected_entry_ids, page_1_entry_ids + page_2_entry_ids
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

  test "mark_as_recurring allows a second manual recurring transaction with same merchant but different amount" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Test Merchant"
    entry = create_transaction(account: account, amount: 34, merchant: merchant)
    transaction = entry.entryable

    # Existing manual recurring row for the same merchant, but a different amount
    family.recurring_transactions.create!(
      account: account,
      merchant: merchant,
      amount: 12,
      currency: entry.currency,
      expected_day_of_month: entry.date.day,
      last_occurrence_date: entry.date,
      next_expected_date: 1.month.from_now,
      status: "active",
      manual: true,
      occurrence_count: 1
    )

    assert_difference "family.recurring_transactions.count", 1 do
      post mark_as_recurring_transaction_path(transaction)
    end

    assert_redirected_to transactions_path
    assert_equal "Transaction marked as recurring", flash[:notice]
  end

  test "mark_as_recurring allows a second manual recurring transaction with same name but different amount" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    entry = create_transaction(account: account, name: "Example Payee", amount: 34)
    transaction = entry.entryable

    # Existing manual recurring row for the same payee name, but a different amount
    family.recurring_transactions.create!(
      account: account,
      name: "Example Payee",
      amount: 12,
      currency: entry.currency,
      expected_day_of_month: entry.date.day,
      last_occurrence_date: entry.date,
      next_expected_date: 1.month.from_now,
      status: "active",
      manual: true,
      occurrence_count: 1
    )

    assert_difference "family.recurring_transactions.count", 1 do
      post mark_as_recurring_transaction_path(transaction)
    end

    assert_redirected_to transactions_path
    assert_equal "Transaction marked as recurring", flash[:notice]
  end

  test "mark_as_recurring shows alert if recurring transaction with same name and amount already exists" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    entry = create_transaction(account: account, name: "Example Payee", amount: 100)
    transaction = entry.entryable

    family.recurring_transactions.create!(
      account: account,
      name: "Example Payee",
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

  test "mark_as_recurring shows already-exists alert when a concurrent request wins the race" do
    family = families(:empty)
    sign_in users(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    merchant = family.merchants.create! name: "Test Merchant"
    entry = create_transaction(account: account, amount: 100, merchant: merchant)
    transaction = entry.entryable

    # Simulate another request creating the identical pattern between our
    # pre-check and our create call.
    RecurringTransaction.expects(:create_from_transaction).raises(
      ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint")
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

  test "new renders category and merchant selectors in German" do
    get new_transaction_url(locale: "de")

    assert_response :success

    assert_select "[data-controller='category-select']" do
      assert_select "input[type='search'][placeholder=?]", "Kategorien suchen"
      assert_select "[data-category-select-create-label-value=?]", "„__CATEGORY_NAME__“ erstellen"
      assert_select "[data-category-select-create-error-message-value=?]", "Kategorie konnte nicht erstellt werden"
    end

    assert_select "[data-controller='merchant-select']" do
      assert_select "input[type='search'][placeholder=?]", "Händler suchen oder erstellen"
      assert_select "[data-merchant-select-error-message-value=?]", "Händler konnte nicht erstellt werden"
      assert_select "[data-merchant-select-target='createForm']", text: /Erstellen/
    end
  end

  test "new groups subcategories immediately after their parent in the category select" do
    get new_transaction_url
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    trigger = doc.at_css("#category_id_trigger")
    assert_not_nil trigger, "expected the category select trigger button to render"

    wrapper = trigger.ancestors(".relative").first
    category_values = wrapper.css("[data-value]").map { |node| node["data-value"] }

    parent_index = category_values.index(categories(:food_and_drink).id)
    child_index = category_values.index(categories(:subcategory).id)

    assert_not_nil parent_index
    assert_not_nil child_index
    assert_equal parent_index + 1, child_index

    child_option = wrapper.at_css("[data-category-id='#{categories(:subcategory).id}']")
    assert_not_nil child_option, "expected the subcategory option to render"
    assert child_option.at_css("[data-testid='category-select-subcategory-indicator']"),
           "expected the subcategory option to show the hierarchy indicator used in Settings"
  end

  test "new renders a search box for account selection" do
    get new_transaction_url
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    trigger = doc.at_css("#account_id_trigger")
    assert_not_nil trigger, "expected the account select trigger button to render"

    wrapper = trigger.ancestors(".relative").first
    assert_not_nil wrapper.at_css("input[type='search']"), "expected a search input inside the account select"
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

  test "new preloads transaction form option data" do
    family = families(:empty)
    user = users(:empty)
    sign_in user

    manual_account_ids = []
    4.times do |idx|
      account = family.accounts.create!(
        name: "Manual Account #{idx}",
        balance: 0,
        currency: "USD",
        accountable: Depository.new
      )
      assert Account.manual.active.exists?(id: account.id), "Account should be included in the manual active scope"
      manual_account_ids << account.id
      family.categories.create!(
        name: "Category #{idx}",
        color: "#000000",
        lucide_icon: "shapes"
      )
      family.merchants.create!(name: "Merchant #{idx}")
      family.tags.create!(name: "Tag #{idx}")
    end

    inaccessible_account = families(:dylan_family).accounts.create!(
      name: "Other Family Account",
      balance: 0,
      currency: "EUR",
      accountable: Depository.new
    )

    queries = capture_sql_queries { get new_transaction_url }

    assert_response :success
    assert_select "input[name='entry[account_id]']"
    assert_select "input[name='entry[entryable_attributes][category_id]']"
    assert_select "input[name='entry[entryable_attributes][merchant_id]']"
    assert_select "form[data-transaction-form-account-currencies-value]" do |forms|
      account_currencies = JSON.parse(forms.first["data-transaction-form-account-currencies-value"])
      manual_account_ids.each do |account_id|
        assert_equal "USD", account_currencies[account_id.to_s]
      end
      assert_nil account_currencies[inaccessible_account.id.to_s]
    end

    assert_empty queries.grep(/FROM "account_providers" WHERE "account_providers"\."account_id" =/)
    assert_operator queries.grep(/FROM "active_storage_attachments" WHERE "active_storage_attachments"\."record_id" =/).size, :<=, 1
    assert_operator queries.grep(/SELECT "categories"\.\* FROM "categories" WHERE "categories"\."family_id" =/).size, :<=, 1
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

  test "index preloads transfer counterparty entry and account to avoid N+1" do
    family = @user.family
    from_account = family.accounts.visible.first
    to_account = family.accounts.create!(
      name: "Transfer Counterparty",
      currency: family.currency,
      balance: 0,
      accountable: Depository.new
    )

    transfers = 6.times.map do |i|
      create_transfer(
        from_account: from_account,
        to_account: to_account,
        amount: 25 + i,
        date: Date.current - i.days
      )
    end

    queries = capture_sql_queries do
      # per_page must fit all transfer legs + fixtures so assertions below
      # actually exercise the transfer render path this preload protects.
      get transactions_url(per_page: 50)
    end

    assert_response :success

    # Index dedupes transfers to the outflow side; assert those rows rendered so
    # the SQL assertions below actually exercise Transfer#to_account.
    rendered_ids = rendered_entry_ids
    transfers.each do |transfer|
      assert_includes rendered_ids, transfer.outflow_transaction.entry.id.to_s,
                      "Expected transfer outflow entry to render on the index"
    end

    # Transfer#categorizable? / #payment? walk to_account via
    # transfer.inflow_transaction.entry.account. Without nested includes those
    # become one lookup triad per transfer row during list render.
    normalized_queries = queries.map { |sql| normalize_sql_query(sql) }
    assert_empty single_record_lookups(normalized_queries, table: "transactions", column: "id"),
                 "Expected transfer counterparty transactions to be preloaded"
    assert_empty single_record_lookups(normalized_queries, table: "entries", column: "entryable_id"),
                 "Expected transfer counterparty entries to be preloaded"
    assert_empty single_record_lookups(normalized_queries, table: "accounts", column: "id"),
                 "Expected transfer counterparty accounts to be preloaded"
  end

  test "index caches uncategorized_count and projected_recurring across requests" do
    # Test environment uses null_store; swap in a memory store so the cache
    # actually persists between the two requests below.
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    get transactions_url
    assert_response :success

    queries = capture_sql_queries { get transactions_url }
    assert_response :success

    # uncategorized_transactions is a scope (joins/wheres), so its name never
    # appears in the generated SQL -- match the COUNT query it produces instead.
    assert_empty queries.select { |q| q =~ /SELECT COUNT/i && q =~ /category_id.*IS NULL/i },
      "second request with unchanged data should reuse the cached uncategorized count"
    # Building the cache key itself still runs small COUNT/MAX queries against
    # recurring_transactions (Family#recurring_transactions_version and
    # #recurring_transaction_merchants_version), so match the projection query
    # the cached block itself would run instead of the whole table name.
    assert_empty queries.grep(/next_expected_date/i),
      "second request with unchanged data should reuse the cached projected recurring lookup"
  ensure
    Rails.cache = original_cache
  end

  test "index uncategorized_count cache reflects new transactions immediately" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    get transactions_url
    initial_count = rendered_uncategorized_count

    account = @user.family.accounts.visible.first
    account.entries.create!(
      name: "New uncategorized transaction",
      amount: 42,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )

    get transactions_url
    updated_count = rendered_uncategorized_count

    assert_equal initial_count + 1, updated_count,
      "a new uncategorized transaction must be reflected without a stale cache read"
  ensure
    Rails.cache = original_cache
  end

  test "index uncategorized_count cache reflects categorizing a transaction immediately" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    entry = @user.family.accounts.visible.first.entries.create!(
      name: "Needs a category",
      amount: 42,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )

    get transactions_url
    initial_count = rendered_uncategorized_count

    entry.entryable.update!(category: categories(:food_and_drink))

    get transactions_url
    updated_count = rendered_uncategorized_count

    assert_equal initial_count - 1, updated_count,
      "categorizing a transaction must be reflected without a stale cache read"
  ensure
    Rails.cache = original_cache
  end

  test "index uncategorized_count cache is invalidated when account-share access is revoked" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    member = users(:family_member)
    share = account_shares(:depository_shared_with_member)
    share.account.entries.create!(
      name: "Uncategorized on shared account",
      amount: 42,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )

    sign_in member
    get transactions_url
    count_with_access = rendered_uncategorized_count
    assert_operator count_with_access, :>, 0,
      "the member should see the shared account's uncategorized transaction before revocation"

    share.destroy!

    get transactions_url
    count_after_revocation = rendered_uncategorized_count

    assert_operator count_after_revocation, :<, count_with_access,
      "revoking account-share access must not leave a stale cached count that still includes the now-inaccessible account"
  ensure
    Rails.cache = original_cache
  end

  test "index projected_recurring cache is invalidated when account-share access is revoked" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    member = users(:family_member)
    share = account_shares(:depository_shared_with_member)
    recurring = recurring_transactions(:netflix_subscription)
    assert_equal share.account_id, recurring.account_id,
      "fixture assumption: the shared depository account has the netflix recurring charge"

    merchant_name_pattern = /#{Regexp.escape(recurring.merchant.name)}/

    sign_in member
    get transactions_url
    assert_match merchant_name_pattern, response.body,
      "the member should see the shared account's recurring transaction before revocation"

    share.destroy!

    get transactions_url
    assert_no_match merchant_name_pattern, response.body,
      "revoking account-share access must not leave a stale cached projected-recurring list"
  ensure
    Rails.cache = original_cache
  end

  test "index projected_recurring cache reflects a merchant rename immediately" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    recurring = recurring_transactions(:netflix_subscription)
    merchant = recurring.merchant

    get transactions_url
    assert_match(/#{Regexp.escape(merchant.name)}/, response.body,
      "the recurring transaction should render with the merchant's original name")

    merchant.update!(name: "Netflix Renamed")

    get transactions_url
    assert_match(/Netflix Renamed/, response.body,
      "renaming the merchant must not leave a stale cached projected-recurring list")
  ensure
    Rails.cache = original_cache
  end

  test "index projected_recurring cache reflects a provider merchant update immediately" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    # Recurring detection copies transaction.merchant_id, which can point at a
    # shared ProviderMerchant (not just a family-owned FamilyMerchant) -- e.g.
    # ProviderMerchant::Enhancer updates these after the recurring row exists.
    provider_merchant = ProviderMerchant.create!(name: "Provider Merchant Original", source: "enable_banking")
    recurring = recurring_transactions(:netflix_subscription)
    recurring.update!(merchant: provider_merchant, name: nil)

    get transactions_url
    assert_match(/Provider Merchant Original/, response.body,
      "the recurring transaction should render with the provider merchant's original name")

    provider_merchant.update!(name: "Provider Merchant Renamed")

    get transactions_url
    assert_match(/Provider Merchant Renamed/, response.body,
      "updating the provider merchant must not leave a stale cached projected-recurring list")
  ensure
    Rails.cache = original_cache
  end

  test "index uncategorized_count cache reflects deleting an uncategorized transaction immediately" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    entry = @user.family.accounts.visible.first.entries.create!(
      name: "Deleted while uncategorized",
      amount: 42,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )

    get transactions_url
    initial_count = rendered_uncategorized_count

    entry.destroy!

    get transactions_url
    updated_count = rendered_uncategorized_count

    assert_equal initial_count - 1, updated_count,
      "deleting an uncategorized transaction must not leave a stale cached count"
  ensure
    Rails.cache = original_cache
  end

  test "index uncategorized_count cache reflects disabling an account immediately" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    account = @user.family.accounts.visible.first
    account.entries.create!(
      name: "Uncategorized on account about to be disabled",
      amount: 42,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )

    get transactions_url
    initial_count = rendered_uncategorized_count
    assert_operator initial_count, :>, 0

    account.disable!

    get transactions_url
    updated_count = rendered_uncategorized_count

    assert_operator updated_count, :<, initial_count,
      "disabling an account must not leave a stale cached count that still includes its transactions"
  ensure
    Rails.cache = original_cache
  end

  test "index uncategorized_count cache is scoped per user, not just per family" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    # family_member has no share on this account (see test/fixtures/account_shares.yml),
    # so only the admin can see its uncategorized transaction.
    accounts(:other_asset).entries.create!(
      name: "Admin-only uncategorized transaction",
      amount: 42,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )

    get transactions_url
    admin_count = rendered_uncategorized_count
    assert_operator admin_count, :>, 0

    sign_in users(:family_member)
    get transactions_url
    member_count = rendered_uncategorized_count

    assert_not_equal admin_count, member_count,
      "a member without access to the admin-only account must not reuse the admin's cached uncategorized count"
  ensure
    Rails.cache = original_cache
  end

  private
    def rendered_entry_ids
      css_select("turbo-frame[id^='entry_']").map { |node| node["id"].delete_prefix("entry_") }
    end

    def normalize_sql_query(sql)
      sql.to_s.squish.gsub(/[`"]/, "").downcase
    end

    # The "Categorize (N)" menu item only renders when @uncategorized_count
    # is positive, so an absent match means the count is 0.
    def rendered_uncategorized_count
      match = response.body.match(/Categorize \((\d+)\)/)
      match ? match[1].to_i : 0
    end

    # Per-row lazy loads use `column = ?`. Do not treat `IN (...)` as lazy
    # loads — ActiveRecord nested preloads also use single-value IN when only
    # one associated record is needed (e.g. one counterparty account).
    def single_record_lookups(normalized_queries, table:, column:)
      pattern = /
        from\s+#{Regexp.escape(table)}\s+
        where\s+#{Regexp.escape(table)}\.#{Regexp.escape(column)}\s*=
      /x

      normalized_queries.grep(pattern)
    end

    def capture_sql_queries
      queries = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:cached]
        next if %w[SCHEMA TRANSACTION].include?(payload[:name])

        queries << payload[:sql].squish
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        yield
      end

      queries
    end
end
