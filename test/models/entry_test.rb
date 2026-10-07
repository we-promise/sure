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
end
