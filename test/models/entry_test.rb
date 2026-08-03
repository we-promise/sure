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

  test "uncategorized reporting follows confirmed transfers instead of kind" do
    source = accounts(:depository)
    destination = source.family.accounts.where.not(id: source.id).first
    kind_hint = create_transaction(account: source, kind: "funds_movement", category: nil)
    transfer = create_transfer(from_account: source, to_account: destination, amount: 100)
    transfer.inflow_transaction.update!(kind: "standard")
    transfer.outflow_transaction.update!(kind: "standard")

    result_ids = Entry.where(id: [ kind_hint.id, transfer.inflow_transaction.entry.id, transfer.outflow_transaction.entry.id ])
                      .uncategorized_transactions
                      .pluck(:id)

    assert_includes result_ids, kind_hint.id
    assert_not_includes result_ids, transfer.inflow_transaction.entry.id
    assert_not_includes result_ids, transfer.outflow_transaction.entry.id
  end
end
