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

  test "bulk_update! locks the category when it also changes tags" do
    entry = create_transaction(account: accounts(:depository))

    Entry.where(id: entry.id).bulk_update!({ category_id: categories(:income).id, tag_ids: [ tags(:one).id ] }, update_tags: true)

    transaction = entry.reload.transaction
    assert transaction.locked?(:category_id)
    assert transaction.locked?(:tag_ids)
    assert entry.user_modified?
  end

  test "save_and_lock_attributes flags the entry and locks its tags in the same transaction" do
    entry = create_transaction(account: accounts(:depository))
    entry.stubs(:mark_user_modified!).raises(ActiveRecord::RecordInvalid.new(entry))

    assert_raises(ActiveRecord::RecordInvalid) do
      entry.save_and_lock_attributes(user_modified: true, lock_tags: :always) { entry.update(name: "User name") }
    end

    entry.reload
    assert_not_equal "User name", entry.name
    assert_not entry.locked?(:name)
    assert_not entry.transaction.locked?(:tag_ids)
  end

  test "save_and_lock_attributes rolls back what the block wrote when it fails" do
    entry = create_transaction(account: accounts(:depository))

    assert_not entry.save_and_lock_attributes(user_modified: true, lock_tags: :always) {
      entry.transaction.tag_ids = [ tags(:one).id ]
      false
    }

    entry.reload
    assert_empty entry.transaction.tag_ids
    assert_not entry.user_modified?
    assert_not entry.transaction.locked?(:tag_ids)
  end

  test "save_and_lock_attributes rolls back inside an outer transaction too" do
    entry = create_transaction(account: accounts(:depository))

    Entry.transaction do
      assert_not entry.save_and_lock_attributes {
        entry.transaction.tag_ids = [ tags(:one).id ]
        false
      }
    end

    assert_empty entry.reload.transaction.tag_ids
  end

  test "save_and_lock_attributes keeps locks committed after the entry was loaded" do
    entry = create_transaction(account: accounts(:depository))
    Entry.where(id: entry.id).update_all(locked_attributes: { "notes" => Time.current })

    assert entry.save_and_lock_attributes { entry.update(name: "User name") }

    entry.reload
    assert entry.locked?(:notes)
    assert entry.locked?(:name)
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
end
