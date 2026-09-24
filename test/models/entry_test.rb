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

  test "opening anchor sorts before a same-day transaction, unlike other valuations" do
    account = families(:dylan_family).accounts.create!(
      name: "Same-day ordering account", currency: "USD", accountable: Depository.new, balance: 0, cash_balance: 0
    )

    opening_anchor = create_valuation(account: account, kind: "opening_anchor", date: Date.new(2024, 1, 1), amount: 1000)
    same_day_transaction = create_transaction(account: account, date: Date.new(2024, 1, 1))

    # opening_anchor is a pre-entry baseline, so it's the EARLIEST entry of its date.
    assert_equal [ opening_anchor.id, same_day_transaction.id ], account.entries.chronological.pluck(:id)
    assert_equal [ same_day_transaction.id, opening_anchor.id ], account.entries.reverse_chronological.pluck(:id)

    reconciliation = create_valuation(account: account, kind: "reconciliation", date: Date.new(2024, 1, 5), amount: 900)
    other_same_day_transaction = create_transaction(account: account, date: Date.new(2024, 1, 5))

    # A reconciliation is a point-in-time snapshot, so it stays the LATEST entry of its date.
    assert_equal [ other_same_day_transaction.id, reconciliation.id ], account.entries.chronological.where(date: Date.new(2024, 1, 5)).pluck(:id)
    assert_equal [ reconciliation.id, other_same_day_transaction.id ], account.entries.reverse_chronological.where(date: Date.new(2024, 1, 5)).pluck(:id)
  end

  test "bulk_update! touches the assigned category's last_used_at" do
    entry = create_transaction(account: accounts(:depository))
    category = categories(:income)
    assert_nil category.last_used_at

    Entry.where(id: entry.id).bulk_update!({ category_id: category.id })

    assert_not_nil category.reload.last_used_at
  end
end
