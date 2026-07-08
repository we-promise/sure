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

  test "split_parent_ids_for returns only ids that are split parents" do
    account = accounts(:depository)
    split_parent = create_transaction(account: account, amount: 100)
    split_parent.split!([ { name: "Part 1", amount: 60, category_id: nil }, { name: "Part 2", amount: 40, category_id: nil } ])
    plain_entry = create_transaction(account: account, amount: 50)

    result = Entry.split_parent_ids_for([ split_parent.id, plain_entry.id ])

    assert_equal Set.new([ split_parent.id ]), result
  end

  test "split_parent_ids_for returns an empty set for blank input" do
    assert_equal Set.new, Entry.split_parent_ids_for([])
    assert_equal Set.new, Entry.split_parent_ids_for(nil)
  end
end
