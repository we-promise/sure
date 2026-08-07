require "test_helper"

class EntryTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @entry = entries :transaction
  end

  test "entry cannot be older than 10 years ago" do
    assert_raises ActiveRecord::RecordInvalid do
      @entry.update! date: 50.years.ago.to_date
    end
  end

  # Future-dated transactions are allowed (#1080). They appear in the
  # activity feed with a Scheduled badge and don't affect today's
  # balance until they post.
  test "transaction entry can be saved with a future date" do
    assert_nothing_raised do
      @entry.update! date: 10.days.from_now.to_date
    end
    assert @entry.reload.date.future?
  end

  test "valuations cannot have more than one entry per day" do
    existing_valuation = entries :valuation

    new_valuation = Entry.new \
      entryable: Valuation.new(kind: "reconciliation"),
      account: existing_valuation.account,
      date: existing_valuation.date, # invalid
      currency: existing_valuation.currency,
      amount: existing_valuation.amount

    assert new_valuation.invalid?
  end

  test "triggers sync with correct start date when transaction is set to prior date" do
    prior_date = @entry.date - 1
    @entry.update! date: prior_date

    @entry.account.expects(:sync_later).with(window_start_date: prior_date)
    @entry.sync_account_later
  end

  test "triggers sync with correct start date when transaction is set to future date" do
    prior_date = @entry.date
    @entry.update! date: @entry.date + 1

    @entry.account.expects(:sync_later).with(window_start_date: prior_date)
    @entry.sync_account_later
  end

  test "triggers sync with correct start date when transaction deleted" do
    @entry.destroy!

    @entry.account.expects(:sync_later).with(window_start_date: nil)
    @entry.sync_account_later
  end

  test "can search entries" do
    family = families(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
    category = family.categories.first
    merchant = family.merchants.first

    create_transaction(account: account, name: "a transaction")
    create_transaction(account: account, name: "ignored")
    create_transaction(account: account, name: "third transaction", category: category, merchant: merchant)

    params = { search: "a" }

    assert_equal 2, family.entries.search(params).size

    params = { search: "%" }
    assert_equal 0, family.entries.search(params).size
  end

  test "status filter matches pending transactions for every supported provider via EntrySearch" do
    family = families(:empty)
    account = family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new

    confirmed = create_transaction(account: account, amount: 50, kind: "standard")

    pending_by_provider = Transaction::PENDING_PROVIDERS.index_with do |provider|
      entry = create_transaction(account: account, amount: 50, kind: "standard")
      entry.entryable.update!(extra: { provider => { "pending" => true } })
      entry.id
    end

    pending_ids = family.entries.search(status: [ "pending" ]).pluck(:id)
    confirmed_ids = family.entries.search(status: [ "confirmed" ]).pluck(:id)

    pending_by_provider.each do |provider, entry_id|
      assert_includes pending_ids, entry_id, "#{provider} pending entry should match the pending filter"
      assert_not_includes confirmed_ids, entry_id, "#{provider} pending entry should be excluded from the confirmed filter"
    end

    assert_includes confirmed_ids, confirmed.id
    assert_not_includes pending_ids, confirmed.id
  end

  test "visible scope only returns entries from visible accounts" do
    # Create transactions for all account types
    visible_transaction = create_transaction(account: accounts(:depository), name: "Visible transaction")
    invisible_transaction = create_transaction(account: accounts(:credit_card), name: "Invisible transaction")

    # Update account statuses
    accounts(:credit_card).disable!

    # Test the scope
    visible_entries = Entry.visible

    # Should include entry from active account
    assert_includes visible_entries, visible_transaction

    # Should not include entry from disabled account
    assert_not_includes visible_entries, invisible_transaction
  end
end
