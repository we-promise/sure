require "test_helper"

class EntryTest < ActiveSupport::TestCase
  include EntriesTestHelper

  test "chronological ordering uses id as final tie breaker" do
    account = accounts(:depository)
    timestamp = Time.zone.parse("2026-05-05 12:00:00")

    entries = 3.times.map do |index|
      create_transaction(
        account: account,
        name: "Same timestamp transaction #{index}",
        date: Date.new(2026, 5, 5),
        created_at: timestamp,
        updated_at: timestamp
      )
    end

    entry_ids = entries.map(&:id)

    assert_equal entry_ids.sort, Entry.where(id: entry_ids).chronological.pluck(:id)
    assert_equal entry_ids.sort.reverse, Entry.where(id: entry_ids).reverse_chronological.pluck(:id)
  end

  # Regression: lock_saved_attributes! and mark_user_modified! save again and used
  # to drop the original date, so moving an entry later double-counted it.
  test "sync_account_later keeps the original date across later saves" do
    entry = create_transaction(account: accounts(:depository), date: 5.days.ago.to_date)
    original_date = entry.date

    entry.update!(date: 2.days.ago.to_date)
    entry.update!(date: 1.day.ago.to_date)
    entry.lock_saved_attributes!
    entry.mark_user_modified!

    entry.account.expects(:sync_later).with(window_start_date: original_date)
    entry.sync_account_later
  end

  test "bulk_update! touches the assigned category's last_used_at" do
    entry = create_transaction(account: accounts(:depository))
    category = categories(:income)
    assert_nil category.last_used_at

    Entry.where(id: entry.id).bulk_update!({ category_id: category.id })

    assert_not_nil category.reload.last_used_at
  end

  test "descriptive edits do not affect balances" do
    entry = create_transaction(account: accounts(:depository), amount: 100)
    entry = Entry.find(entry.id)

    entry.update!(name: "Renamed", notes: "note", entryable_attributes: { id: entry.entryable_id, category_id: categories(:food_and_drink).id })

    assert_not entry.saved_changes_affect_balances?
  end

  # A descriptive change must never mask a balance-relevant change made in
  # the same update.
  test "descriptive edits combined with a balance edit still affect balances" do
    entry = create_transaction(account: accounts(:depository), amount: 100)

    entry = Entry.find(entry.id)
    entry.update!(notes: "x", amount: 150)
    assert entry.saved_changes_affect_balances?

    entry = Entry.find(entry.id)
    entry.update!(date: 3.days.ago.to_date, entryable_attributes: { id: entry.entryable_id, category_id: categories(:food_and_drink).id })
    assert entry.saved_changes_affect_balances?
  end

  test "amount, date and exchange rate edits affect balances" do
    entry = create_transaction(account: accounts(:depository), amount: 100)

    entry = Entry.find(entry.id)
    entry.update!(amount: 150)
    assert entry.saved_changes_affect_balances?

    entry = Entry.find(entry.id)
    entry.update!(date: 3.days.ago.to_date)
    assert entry.saved_changes_affect_balances?

    entry = Entry.find(entry.id)
    entry.update!(entryable_attributes: { id: entry.entryable_id, exchange_rate: 1.2 })
    assert entry.saved_changes_affect_balances?
  end

  test "reconcile_pending_duplicates excludes a pending with one unambiguous booked match" do
    account = accounts(:depository)
    pending = create_pending(account, date: 3.days.ago.to_date, amount: 25)
    create_transaction(account: account, date: 1.day.ago.to_date, amount: 25)

    Entry.reconcile_pending_duplicates(account: account)

    assert pending.reload.excluded?
  end

  test "reconcile_pending_duplicates keeps both same-amount pendings when only one booked" do
    account = accounts(:depository)
    first = create_pending(account, date: 3.days.ago.to_date, amount: 20)
    second = create_pending(account, date: 2.days.ago.to_date, amount: 20)
    create_transaction(account: account, date: 1.day.ago.to_date, amount: 20)

    Entry.reconcile_pending_duplicates(account: account)

    assert_not first.reload.excluded?
    assert_not second.reload.excluded?
  end

  test "reconcile_pending_duplicates suggests no fuzzy match when the exact match is ambiguous" do
    account = accounts(:depository)
    first = create_pending(account, date: 3.days.ago.to_date, amount: 5)
    second = create_pending(account, date: 2.days.ago.to_date, amount: 5)
    first.update!(name: "Starbucks Store")
    second.update!(name: "Starbucks Store")
    create_transaction(account: account, date: 1.day.ago.to_date, amount: 5, name: "Starbucks Store")

    Entry.reconcile_pending_duplicates(account: account)

    assert_nil first.reload.transaction.extra["potential_posted_match"]
    assert_nil second.reload.transaction.extra["potential_posted_match"]
  end

  test "reconcile_pending_duplicates suggests no fuzzy match when two bookings match exactly" do
    account = accounts(:depository)
    pending = create_pending(account, date: 3.days.ago.to_date, amount: 5)
    pending.update!(name: "Starbucks Store")
    create_transaction(account: account, date: 2.days.ago.to_date, amount: 5, name: "Starbucks Store")
    create_transaction(account: account, date: 1.day.ago.to_date, amount: 5, name: "Card payment")

    Entry.reconcile_pending_duplicates(account: account)

    assert_not pending.reload.excluded?
    assert_nil pending.transaction.extra["potential_posted_match"]
  end

  test "reconcile_pending_duplicates ignores a booked entry from another provider" do
    account = accounts(:depository)
    pending = create_pending(account, date: 3.days.ago.to_date, amount: 30)
    pending.update_columns(source: "simplefin")
    booked = create_transaction(account: account, date: 1.day.ago.to_date, amount: 30)
    booked.update_columns(source: "lunchflow")

    Entry.reconcile_pending_duplicates(account: account)

    assert_not pending.reload.excluded?
  end

  test "reconcile_pending_duplicates does not suggest a fuzzy match from another provider" do
    account = accounts(:depository)
    pending = create_pending(account, date: 3.days.ago.to_date, amount: 30)
    pending.update_columns(source: "simplefin")
    booked = create_transaction(account: account, date: 2.days.ago.to_date, amount: 33)
    booked.update_columns(source: "lunchflow")

    Entry.reconcile_pending_duplicates(account: account)

    assert_nil pending.reload.transaction.extra["potential_posted_match"]
  end

  private
    def create_pending(account, date:, amount:)
      create_transaction(
        account: account, date: date, amount: amount,
        entryable: Transaction.new(extra: { "simplefin" => { "pending" => true } })
      )
    end
end
