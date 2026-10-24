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

  test "auto_exclude_stale_pending records why it excluded the entry" do
    account = accounts(:depository)
    travel_to Time.zone.parse("2026-10-03 06:00:00")
    stale = create_pending(account, date: 10.days.ago.to_date, amount: 40)
    stale.update_columns(source: "simplefin")
    fresh = create_pending(account, date: 2.days.ago.to_date, amount: 41)

    assert_equal 1, Entry.auto_exclude_stale_pending(account: account)

    stale.reload
    assert stale.excluded?
    enrichment = stale.auto_exclusion
    assert_equal true, enrichment.value
    assert_equal({ "reason" => "stale_pending", "provider" => "simplefin", "days" => 8 }, enrichment.metadata)
    assert_equal Time.zone.parse("2026-10-03 06:00:00"), enrichment.updated_at
    assert_equal({ "simplefin" => { "pending" => true } }, stale.transaction.extra, "provider data stays untouched")

    assert_not fresh.reload.excluded?
    assert_empty fresh.data_enrichments
  end

  test "auto_exclude_stale_pending leaves entries the user already excluded alone" do
    account = accounts(:depository)
    manual = create_pending(account, date: 10.days.ago.to_date, amount: 40)
    manual.update!(excluded: true)

    assert_equal 0, Entry.auto_exclude_stale_pending(account: account)
    assert_nil manual.reload.auto_exclusion
    assert_empty manual.data_enrichments
  end

  test "auto_exclude_stale_pending keeps an entry the user turned Exclude off for" do
    account = accounts(:depository)
    pending = create_pending(account, date: 10.days.ago.to_date, amount: 40)
    pending.lock_attr!(:excluded)

    assert_equal 0, Entry.auto_exclude_stale_pending(account: account)
    assert_not pending.reload.excluded?
  end

  test "auto_exclude_stale_pending still excludes an entry without locked attributes" do
    account = accounts(:depository)
    pending = create_pending(account, date: 10.days.ago.to_date, amount: 40)
    pending.update_columns(locked_attributes: nil)

    assert_equal 1, Entry.auto_exclude_stale_pending(account: account)
    assert pending.reload.excluded?
  end

  test "auto_exclude_stale_pending refreshes the record when it excludes again" do
    account = accounts(:depository)
    pending = create_pending(account, date: 10.days.ago.to_date, amount: 40)
    Entry.auto_exclude_stale_pending(account: account)
    pending.reload.update_columns(excluded: false)

    travel 1.day do
      assert_equal 1, Entry.auto_exclude_stale_pending(account: account)
      assert_equal 1, pending.data_enrichments.count
      assert_in_delta Time.current, pending.reload.auto_exclusion.updated_at, 1.second
    end
  end

  test "reconcile_pending_duplicates records the posted match it excluded the pending for" do
    account = accounts(:depository)
    pending = create_pending(account, date: 3.days.ago.to_date, amount: 25)
    pending.update_columns(source: "enable_banking")
    booked = create_transaction(account: account, date: 1.day.ago.to_date, amount: 25)
    booked.update_columns(source: "enable_banking")

    Entry.reconcile_pending_duplicates(account: account)

    assert pending.reload.excluded?
    assert_equal({ "reason" => "posted_match", "provider" => "enable_banking", "matched_entry_id" => booked.id }, pending.auto_exclusion.metadata)
  end

  test "reconcile_pending_duplicates dry run records nothing" do
    account = accounts(:depository)
    pending = create_pending(account, date: 3.days.ago.to_date, amount: 25)
    create_transaction(account: account, date: 1.day.ago.to_date, amount: 25)

    Entry.reconcile_pending_duplicates(account: account, dry_run: true)

    assert_not pending.reload.excluded?
    assert_empty pending.data_enrichments
  end

  test "turning Exclude off by hand ends the automatic exclusion explanation" do
    account = accounts(:depository)
    pending = create_pending(account, date: 10.days.ago.to_date, amount: 40)
    Entry.auto_exclude_stale_pending(account: account)
    assert pending.reload.auto_exclusion

    pending.update!(excluded: false)
    assert_empty pending.data_enrichments.where(source: "sync")

    pending.enrich_attribute(:excluded, true, source: "rule")
    assert pending.reload.excluded?
    assert_nil pending.auto_exclusion, "a later exclusion by a rule is not explained as the sync's"
  end

  test "exclude_automatically! lets a validation error through without a record" do
    entry = create_transaction(account: accounts(:depository))
    entry.update_columns(name: "")

    assert_raises(ActiveRecord::RecordInvalid) { entry.exclude_automatically!(reason: "posted_match") }
    assert_not entry.reload.excluded?
    assert_empty entry.data_enrichments, "the record rolls back with the failed exclusion"
  end

  test "excluding by hand records no automatic exclusion" do
    entry = create_transaction(account: accounts(:depository))

    entry.update!(excluded: true)

    assert entry.reload.excluded?
    assert_nil entry.auto_exclusion
  end

  test "exclude_automatically! leaves an entry the user excluded meanwhile alone" do
    entry = create_transaction(account: accounts(:depository))
    Entry.find(entry.id).update!(excluded: true)

    assert_equal false, entry.exclude_automatically!(reason: "posted_match")

    assert entry.reload.excluded?
    assert_nil entry.auto_exclusion
  end

  test "reconcile_pending_duplicates still excludes a kept pending once its posted copy arrives" do
    account = accounts(:depository)
    pending = create_pending(account, date: 3.days.ago.to_date, amount: 25)
    pending.lock_attr!(:excluded)
    create_transaction(account: account, date: 1.day.ago.to_date, amount: 25)

    Entry.reconcile_pending_duplicates(account: account)

    assert pending.reload.excluded?, "a duplicate would otherwise count twice"
    assert_equal "posted_match", pending.auto_exclusion.metadata["reason"]
  end

  test "exclude_automatically! returns false for an entry deleted meanwhile" do
    entry = create_transaction(account: accounts(:depository))
    Entry.find(entry.id).destroy!

    assert_equal false, entry.exclude_automatically!(reason: "posted_match")
  end

  test "reconcile_pending_duplicates does not count an entry the user excluded meanwhile" do
    account = accounts(:depository)
    create_pending(account, date: 3.days.ago.to_date, amount: 25)
    create_transaction(account: account, date: 1.day.ago.to_date, amount: 25)
    Entry.any_instance.stubs(:exclude_automatically!).returns(false)

    stats = Entry.reconcile_pending_duplicates(account: account)

    assert_equal 0, stats[:reconciled]
    assert_empty stats[:details]
  end

  test "exclude_automatically! rejects unknown reasons" do
    entry = create_transaction(account: accounts(:depository))

    assert_raises(ArgumentError) { entry.exclude_automatically!(reason: "whatever") }
    assert_not entry.reload.excluded?
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

  private
    def create_pending(account, date:, amount:)
      create_transaction(
        account: account, date: date, amount: amount,
        entryable: Transaction.new(extra: { "simplefin" => { "pending" => true } })
      )
    end
end
