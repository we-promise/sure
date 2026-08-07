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

  test "reconciled_status defaults to unreconciled" do
    entry = create_transaction(account: accounts(:depository))

    assert entry.unreconciled?
    assert_equal "unreconciled", entry.reconciled_status
  end

  test "advance_reconciled_status! cycles unreconciled -> cleared -> reconciled -> unreconciled" do
    entry = create_transaction(account: accounts(:depository))

    entry.advance_reconciled_status!
    assert_equal "cleared", entry.reload.reconciled_status

    entry.advance_reconciled_status!
    assert_equal "reconciled", entry.reload.reconciled_status

    entry.advance_reconciled_status!
    assert_equal "unreconciled", entry.reload.reconciled_status
  end

  test "needs_reconciliation scope includes unreconciled and cleared, excludes reconciled" do
    account = accounts(:depository)
    unreconciled = create_transaction(account: account, name: "Unreconciled")
    cleared = create_transaction(account: account, name: "Cleared")
    reconciled = create_transaction(account: account, name: "Reconciled")

    cleared.update!(reconciled_status: "cleared")
    reconciled.update!(reconciled_status: "reconciled")

    scoped_ids = Entry.where(id: [ unreconciled.id, cleared.id, reconciled.id ]).needs_reconciliation.pluck(:id)

    assert_includes scoped_ids, unreconciled.id
    assert_includes scoped_ids, cleared.id
    assert_not_includes scoped_ids, reconciled.id
  end

  test "cleared_or_reconciled scope includes cleared and reconciled, excludes unreconciled" do
    account = accounts(:depository)
    unreconciled = create_transaction(account: account, name: "Unreconciled")
    cleared = create_transaction(account: account, name: "Cleared")
    reconciled = create_transaction(account: account, name: "Reconciled")

    cleared.update!(reconciled_status: "cleared")
    reconciled.update!(reconciled_status: "reconciled")

    scoped_ids = Entry.where(id: [ unreconciled.id, cleared.id, reconciled.id ]).cleared_or_reconciled.pluck(:id)

    assert_not_includes scoped_ids, unreconciled.id
    assert_includes scoped_ids, cleared.id
    assert_includes scoped_ids, reconciled.id
  end

  test "bulk_update! applies reconciled_status to manual accounts" do
    entry = create_transaction(account: accounts(:depository))
    assert accounts(:depository).manual?

    Entry.where(id: entry.id).bulk_update!({ reconciled_status: "cleared" })

    assert_equal "cleared", entry.reload.reconciled_status
  end

  test "bulk_update! ignores reconciled_status for synced accounts" do
    entry = create_transaction(account: accounts(:connected))
    assert_not accounts(:connected).manual?

    Entry.where(id: entry.id).bulk_update!({ reconciled_status: "cleared" })

    assert_equal "unreconciled", entry.reload.reconciled_status
  end

  test "bulk_update! applies reconciled_status only to manual entries in a mixed selection and reports the accurate count" do
    manual_entry = create_transaction(account: accounts(:depository))
    synced_entry = create_transaction(account: accounts(:connected))

    updated_count = Entry.where(id: [ manual_entry.id, synced_entry.id ])
                          .bulk_update!({ reconciled_status: "cleared" })

    assert_equal "cleared", manual_entry.reload.reconciled_status
    assert_equal "unreconciled", synced_entry.reload.reconciled_status
    assert_equal 1, updated_count, "only the manual entry actually changed, so the reported count should be 1, not 2"
    assert_not synced_entry.user_modified?
  end
end
