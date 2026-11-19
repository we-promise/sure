require "test_helper"

class EntryTest < ActiveSupport::TestCase
  include EntriesTestHelper, ActiveJob::TestHelper

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

  test "an entryable preloaded from its entry reads that entry without a query" do
    entry = create_transaction(account: accounts(:depository), name: "Preloaded", date: Date.new(2026, 5, 5))

    loaded = Entry.where(id: entry.id).includes(:entryable).first

    assert_queries_count(0) do
      assert_same loaded, loaded.entryable.entry
    end
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

  test "bulk_update! with a block reads the tags of all entries in one query" do
    entries = Array.new(3) { create_transaction(account: accounts(:depository)) }
    yielded = []

    assert_queries_match(/FROM "taggings"/, count: 1) do
      Entry.where(id: entries.map(&:id)).bulk_update!({ category_id: categories(:income).id }) { |entry| yielded << entry.id }
    end

    assert_equal entries.map(&:id).sort, yielded.sort
  end

  test "bulk_update! with a block yields only entries whose tags changed" do
    tagged = create_transaction(account: accounts(:depository))
    tagged.transaction.update!(tag_ids: [ tags(:one).id ])
    untagged = create_transaction(account: accounts(:depository))
    yielded = []

    Entry.where(id: [ tagged.id, untagged.id ]).bulk_update!({ tag_ids: [ tags(:one).id ] }, update_tags: true) { |entry| yielded << entry.id }

    assert_equal [ untagged.id ], yielded
  end

  test "reconciling a transaction leaves what rules read unchanged" do
    entry = create_transaction(account: accounts(:depository))
    before = entry.rule_input_snapshot

    entry.update!(reconciled_at: Time.current)

    assert_equal before, entry.rule_input_snapshot
  end

  test "excluding a transaction changes what rules read" do
    entry = create_transaction(account: accounts(:depository))
    before = entry.rule_input_snapshot

    # The split action only splits transactions that aren't excluded.
    entry.update!(excluded: true)

    assert_not_equal before, entry.rule_input_snapshot
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

  test "set_reconciled_status_for_account! updates every transaction on the account" do
    account = Account.create!(
      family: families(:dylan_family),
      name: "Bulk reconcile",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    cleared = create_transaction(account: account, name: "Cleared")
    reconciled = create_transaction(account: account, name: "Reconciled")
    excluded = create_transaction(account: account, name: "Excluded")
    cleared.update!(reconciled_status: "cleared")
    reconciled.update!(reconciled_status: "reconciled")
    excluded.update!(excluded: true)

    updated_count = Entry.set_reconciled_status_for_account!(account, "reconciled")

    assert_equal 3, updated_count
    assert_equal %w[reconciled reconciled reconciled], [ cleared, reconciled, excluded ].map { |entry| entry.reload.reconciled_status }
    assert_not cleared.reload.user_modified?, "reconciling is not an edit, so the entry stays open to auto-categorization"
  end

  test "set_reconciled_status_for_account! accepts every reconciled status" do
    account = accounts(:depository)
    entry = create_transaction(account: account, name: "Cycles")

    Entry.reconciled_statuses.each_key do |status|
      Entry.set_reconciled_status_for_account!(account, status)
      assert_equal status, entry.reload.reconciled_status
    end
  end

  test "set_reconciled_status_for_account! returns zero when the account has no transactions" do
    account = Account.create!(
      family: families(:dylan_family),
      name: "Valuations only",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    create_valuation(account: account, date: 2.days.ago.to_date)

    assert_equal 0, Entry.set_reconciled_status_for_account!(account, "reconciled")
  end

  test "set_reconciled_status_for_account! leaves other accounts, valuations and statement data alone" do
    account = accounts(:depository)
    entry = create_transaction(account: account, name: "Manual entry")
    valuation = create_valuation(account: account, date: 2.days.ago.to_date)
    other_entry = create_transaction(account: accounts(:credit_card), name: "Other account")
    reconciled_at = 3.days.ago.change(usec: 0)
    entry.update_columns(reconciled_at: reconciled_at, reconciled_by_statement_id: nil)

    Entry.set_reconciled_status_for_account!(account, "cleared")

    assert_equal "cleared", entry.reload.reconciled_status
    assert_equal reconciled_at, entry.reconciled_at
    assert_equal "unreconciled", valuation.reload.reconciled_status
    assert_equal "unreconciled", other_entry.reload.reconciled_status
  end

  test "set_reconciled_status_for_account! updates split children but not the split parent" do
    account = accounts(:depository)
    parent = create_transaction(account: account, name: "Split parent", amount: 100)
    parent.split!([ { name: "Part 1", amount: 60 }, { name: "Part 2", amount: 40 } ])
    parent.reload

    Entry.set_reconciled_status_for_account!(account, "cleared")

    assert_equal "unreconciled", parent.reconciled_status, "the activity list hides split parents, so their status stays untouched"
    assert_equal %w[cleared cleared], parent.child_entries.map { |child| child.reload.reconciled_status }
  end

  test "set_reconciled_status_for_account! changes the row cache key" do
    account = accounts(:depository)
    entry = create_transaction(account: account, name: "Cached row")
    entry.update_columns(updated_at: 1.day.ago)
    old_key = entry.reload.cache_key_with_version

    Entry.set_reconciled_status_for_account!(account, "reconciled")

    assert_not_equal old_key, entry.reload.cache_key_with_version
  end

  test "set_reconciled_status_for_account! locks entries by id before updating them" do
    account = accounts(:depository)
    create_transaction(account: account, name: "Locked row")

    payloads = []
    callback = ->(_name, _started, _finished, _unique_id, payload) { payloads << payload }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Entry.set_reconciled_status_for_account!(account, "cleared")
    end

    lock_index = payloads.index { |payload| payload[:sql].include?("FOR UPDATE OF entries") }
    update_index = payloads.index { |payload| payload[:sql].start_with?('UPDATE "entries"') }

    assert lock_index, "expected an entry lock"
    assert update_index, "expected the entry update"
    assert_operator lock_index, :<, update_index, "the entries must be locked before the update"
    assert_match(/ORDER BY "entries"\."id" ASC/, payloads[lock_index][:sql])
  end

  test "set_reconciled_status_for_account! rejects an unknown status" do
    assert_raises(ArgumentError) do
      Entry.set_reconciled_status_for_account!(accounts(:depository), "bogus")
    end
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

  test "bulk_update! reconciling alone does not lock saved attributes, matching advance_reconciled_status!" do
    entry = create_transaction(account: accounts(:depository), category: categories(:food_and_drink))

    Entry.where(id: entry.id).bulk_update!({ reconciled_status: "cleared" })
    entry.reload

    assert_equal "cleared", entry.reconciled_status
    assert_not entry.user_modified?, "reconciling alone shouldn't lock the entry from future auto-categorization, same as clicking the badge does"
  end

  test "bulk_update! locks saved attributes when reconciled_status is combined with a real edit" do
    entry = create_transaction(account: accounts(:depository))

    Entry.where(id: entry.id).bulk_update!({ reconciled_status: "cleared", notes: "verified against statement" })
    entry.reload

    assert_equal "cleared", entry.reconciled_status
    assert_equal "verified against statement", entry.notes
    assert entry.user_modified?, "a real edit alongside reconciliation should still lock as before"
  end

  test "bulk_update! syncs each account once and schedules the catch-up job when dates move into the future" do
    account = accounts(:depository)
    entries = [ create_transaction(account: account), create_transaction(account: account) ]
    new_date = 3.days.from_now.to_date

    Account.any_instance.expects(:sync_later).with(window_start_date: Date.current).once

    assert_enqueued_jobs 1, only: EntryScheduledSyncJob do
      Entry.where(id: entries.map(&:id)).bulk_update!({ date: new_date })
    end
  end

  test "bulk_update! neither syncs nor schedules when no date changes" do
    entry = create_transaction(account: accounts(:depository))

    Account.any_instance.expects(:sync_later).never

    assert_no_enqueued_jobs only: EntryScheduledSyncJob do
      Entry.where(id: entry.id).bulk_update!({ notes: "updated" })
    end
  end

  test "scheduled? is true only for entries dated after today" do
    travel_to Date.new(2026, 5, 5) do
      account = accounts(:depository)

      future_entry = create_transaction(account: account, date: 1.day.from_now.to_date)
      today_entry = create_transaction(account: account, date: Date.current)
      past_entry = create_transaction(account: account, date: 1.day.ago.to_date)

      assert future_entry.scheduled?
      assert_not today_entry.scheduled?
      assert_not past_entry.scheduled?
    end
  end

  test "blank name is invalid when auto-generate transaction names is off" do
    families(:dylan_family).update!(auto_generate_transaction_names: false)

    entry = Entry.new(
      account: accounts(:depository),
      name: "",
      date: Date.current,
      currency: "USD",
      amount: 100,
      entryable: Transaction.new
    )

    assert_not entry.valid?
    assert_includes entry.errors[:name], "can't be blank"
  end

  test "auto-generates name from merchant when blank and merchant is set" do
    families(:dylan_family).update!(auto_generate_transaction_names: true)

    entry = create_transaction(
      account: accounts(:depository),
      name: "",
      merchant: merchants(:netflix)
    )

    assert_equal merchants(:netflix).name, entry.name
  end

  test "auto-generates name from category when blank and only category is set" do
    families(:dylan_family).update!(auto_generate_transaction_names: true)

    entry = create_transaction(
      account: accounts(:depository),
      name: "",
      category: categories(:food_and_drink)
    )

    assert_equal categories(:food_and_drink).display_name, entry.name
  end

  test "blank name is still invalid when auto-generate is on but neither merchant nor category is set" do
    families(:dylan_family).update!(auto_generate_transaction_names: true)

    entry = Entry.new(
      account: accounts(:depository),
      name: "",
      date: Date.current,
      currency: "USD",
      amount: 100,
      entryable: Transaction.new
    )

    assert_not entry.valid?
    assert_includes entry.errors[:name], "can't be blank"
  end

  test "combines merchant and category with a dash when both are set" do
    families(:dylan_family).update!(auto_generate_transaction_names: true)

    entry = create_transaction(
      account: accounts(:depository),
      name: "",
      merchant: merchants(:netflix),
      category: categories(:food_and_drink)
    )

    assert_equal "#{categories(:food_and_drink).display_name} - #{merchants(:netflix).name}", entry.name
  end

  test "does not overwrite an explicitly provided name even when auto-generate is on" do
    families(:dylan_family).update!(auto_generate_transaction_names: true)

    entry = create_transaction(
      account: accounts(:depository),
      name: "Explicit name",
      merchant: merchants(:netflix)
    )

    assert_equal "Explicit name", entry.name
  end

  test "generic_name? is true for the auto-generated fallback label" do
    entry = create_transaction(account: accounts(:depository), name: I18n.t("transactions.unknown_name"))

    assert entry.generic_name?
  end

  test "generic_name? is true when the name exactly matches the entry's category" do
    entry = create_transaction(
      account: accounts(:depository),
      name: categories(:food_and_drink).display_name,
      category: categories(:food_and_drink)
    )

    assert entry.generic_name?
  end

  test "generic_name? is false for a distinguishing name" do
    entry = create_transaction(account: accounts(:depository), name: "Starbucks #4521")

    assert_not entry.generic_name?
  end

  test "generic_name? recognizes the unknown-name fallback saved under a different locale" do
    entry = create_transaction(account: accounts(:depository), name: "Unbekannte Transaktion")

    assert entry.generic_name?
  end

  test "generic_name? recognizes a category name saved under a different locale" do
    entry = create_transaction(
      account: accounts(:depository),
      name: "Restaurants & Bars", # German translation of categories(:food_and_drink)
      category: categories(:food_and_drink)
    )

    assert entry.generic_name?
  end

  test "does not auto-generate a name for an already-persisted entry" do
    families(:dylan_family).update!(auto_generate_transaction_names: true)
    entry = create_transaction(account: accounts(:depository), name: "Original name")

    entry.entryable.category = categories(:food_and_drink)
    entry.name = ""

    assert_not entry.valid?
    assert_includes entry.errors[:name], "can't be blank"
  end

  test "does not auto-generate a name for an imported entry" do
    families(:dylan_family).update!(auto_generate_transaction_names: true)
    import = imports(:transaction)

    entry = Entry.new(
      account: accounts(:depository),
      import: import,
      name: "",
      date: Date.current,
      currency: "USD",
      amount: 100,
      entryable: Transaction.new(category: categories(:food_and_drink))
    )

    assert_not entry.valid?
    assert_includes entry.errors[:name], "can't be blank"
  end

  test "does not auto-generate a name for a provider-synced entry" do
    families(:dylan_family).update!(auto_generate_transaction_names: true)

    entry = Entry.new(
      account: accounts(:depository),
      external_id: "plaid_txn_123",
      source: "plaid",
      name: "",
      date: Date.current,
      currency: "USD",
      amount: 100,
      entryable: Transaction.new(category: categories(:food_and_drink))
    )

    assert_not entry.valid?
    assert_includes entry.errors[:name], "can't be blank"
  end

  test "set_default_name does not raise when entryable is missing" do
    families(:dylan_family).update!(auto_generate_transaction_names: true)

    entry = Entry.new(
      account: accounts(:depository),
      entryable_type: "Transaction",
      name: "",
      date: Date.current,
      currency: "USD",
      amount: 100
    )

    assert_nothing_raised { entry.valid? }
    assert_not entry.valid?
    assert_includes entry.errors[:name], "can't be blank"
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

  test "balance update scopes split reconciliations from every other entry" do
    account = accounts(:connected)
    account.entries.destroy_all
    transaction = create_transaction(account: account)
    reconciliation = create_valuation(account: account, date: 2.days.ago.to_date)
    opening_anchor = create_valuation(account: account, date: 10.days.ago.to_date, kind: "opening_anchor")
    current_anchor = create_valuation(account: account, date: Date.current, kind: "current_anchor")

    assert_equal [ reconciliation ], account.entries.balance_updates.to_a
    assert_equal [ transaction, opening_anchor, current_anchor ].map(&:id).sort,
      account.entries.excluding_balance_updates.pluck(:id).sort
  end

  private
    def create_pending(account, date:, amount:)
      create_transaction(
        account: account, date: date, amount: amount,
        entryable: Transaction.new(extra: { "simplefin" => { "pending" => true } })
      )
    end
end
