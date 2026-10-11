require "test_helper"

class EntryReadTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @admin.update_column(:transactions_read_before, 1.hour.ago)
    @member.update_column(:transactions_read_before, 1.hour.ago)
  end

  test "synced and imported transactions are unread, manual ones are not" do
    synced = create_transaction(external_id: "ext-1", source: "simplefin")
    plaid = create_transaction(plaid_id: "plaid-1")
    imported = create_transaction(import: imports(:transaction))
    manual = create_transaction

    unread_ids = @admin.unread_entries.pluck(:id)

    assert_includes unread_ids, synced.id
    assert_includes unread_ids, plaid.id
    assert_includes unread_ids, imported.id
    assert_not_includes unread_ids, manual.id
  end

  test "transactions created before the watermark count as read" do
    old = create_transaction(external_id: "ext-old", source: "simplefin", created_at: 2.hours.ago)

    assert_not_includes @admin.unread_entries.pluck(:id), old.id
  end

  test "valuations never count as unread" do
    valuation = create_valuation(external_id: "val-1", source: "simplefin")

    assert_not_includes @admin.unread_entries.pluck(:id), valuation.id
  end

  test "read state is per user" do
    entry = create_transaction(external_id: "ext-2", source: "simplefin")

    @admin.mark_entries_read!([ entry.id ])

    assert_not_includes @admin.unread_entries.pluck(:id), entry.id
    assert_includes @member.unread_entries.pluck(:id), entry.id
  end

  test "only accounts the user can access are included" do
    entry = create_transaction(account: accounts(:connected), external_id: "ext-3", source: "plaid")

    assert_includes @admin.unread_entries.pluck(:id), entry.id
    assert_not_includes @member.unread_entries.pluck(:id), entry.id
  end

  test "marking the same entries twice is idempotent" do
    entry = create_transaction(external_id: "ext-4", source: "simplefin")

    assert_difference -> { EntryRead.count }, 1 do
      @admin.mark_entries_read!([ entry.id ])
      @admin.mark_entries_read!([ entry.id, entry.id ])
    end
  end

  test "counts unread transactions per account" do
    2.times { |i| create_transaction(external_id: "ext-count-#{i}", source: "simplefin") }
    create_transaction(account: accounts(:credit_card), external_id: "ext-cc", source: "simplefin")

    counts = @member.unread_entry_counts_by_account

    assert_equal 2, counts[accounts(:depository).id]
    assert_equal 1, counts[accounts(:credit_card).id]
  end

  test "marking all read without a scope moves the watermark and drops per-entry rows" do
    read = create_transaction(external_id: "ext-5", source: "simplefin")
    unread = create_transaction(external_id: "ext-6", source: "simplefin")
    @admin.mark_entries_read!([ read.id ])

    @admin.mark_all_transactions_read!

    assert_empty @admin.unread_entries
    assert_equal 0, @admin.entry_reads.count
    assert_includes @member.unread_entries.pluck(:id), unread.id
  end

  test "marking all read with a scope only touches entries inside it" do
    in_scope = create_transaction(external_id: "ext-7", source: "simplefin")
    out_of_scope = create_transaction(account: accounts(:credit_card), external_id: "ext-8", source: "simplefin")

    @admin.mark_all_transactions_read!(accounts(:depository).entries)

    unread_ids = @admin.unread_entries.pluck(:id)
    assert_not_includes unread_ids, in_scope.id
    assert_includes unread_ids, out_of_scope.id
  end

  test "deleting an entry removes its read rows" do
    entry = create_transaction(external_id: "ext-9", source: "simplefin")
    @admin.mark_entries_read!([ entry.id ])

    assert_difference -> { EntryRead.count }, -1 do
      entry.destroy!
    end
  end

  test "split parents never count as unread because no list shows them" do
    parent = create_transaction(external_id: "ext-split", source: "simplefin", amount: 100)
    parent.split!([
      { name: "Part A", amount: 60, category_id: nil },
      { name: "Part B", amount: 40, category_id: nil }
    ])

    assert_not_includes @admin.unread_entries.pluck(:id), parent.id
  end
end
