require "test_helper"
require_relative "../../support/financekit_test_helper"

class Financekit::MappingTest < ActiveSupport::TestCase
  include FinancekitTestHelper

  setup { financekit_setup }

  test "lossless signs include zero large values and non-two-decimal currencies" do
    %w[0 1 1.234 999999999999999.9999].each do |amount|
      assert_equal BigDecimal(amount), Financekit::Mapping.transaction_amount("amount" => money(amount, "debit"))
      assert_equal(-BigDecimal(amount), Financekit::Mapping.transaction_amount("amount" => money(amount, "credit")))
    end
    assert_equal BigDecimal("42"), Financekit::Mapping.balance(money("42", "credit"), "Depository")
    assert_equal BigDecimal("42"), Financekit::Mapping.balance(money("42", "debit"), "CreditCard")
    assert_equal BigDecimal("100"), Financekit::Payload.money!(money("100", "debit", "JPY"))
    assert_equal BigDecimal("1.234"), Financekit::Payload.money!(money("1.234", "debit", "KWD"))
  end

  test "invalid numeric representations and currency defaults are rejected" do
    [ 1.23, "-1", "NaN", "1e2", "1.12345", "1000000000000000" ].each do |amount|
      assert_raises(Financekit::Error) { Financekit::Payload.money!(money(amount)) }
    end
    assert_raises(Financekit::Error) { Financekit::Payload.money!(money("1", "debit", "NOPE")) }
    assert_raises(Financekit::Error) { Financekit::Payload.money!(money.except("currency")) }
  end

  test "ledger date uses the confirmed account timezone at a month boundary" do
    record = { "transacted_at" => "2026-03-01T00:30:00Z" }
    assert_equal Date.new(2026, 2, 28), Financekit::Mapping.ledger_date(record, "America/Los_Angeles")
    record["posted_at"] = "2026-03-01T08:30:00Z"
    assert_equal Date.new(2026, 3, 1), Financekit::Mapping.ledger_date(record, "America/Los_Angeles")
  end

  { "present" => Date.new(2026, 9, 1), "omitted" => Date.new(2026, 8, 31) }.each do |posted_at, expected_date|
    test "booked transactions with posted_at #{posted_at} import using the existing ledger date precedence" do
      events = financekit_events
      events.last.fetch("transaction").delete("posted_at") if posted_at == "omitted"

      batch = accept_and_apply(financekit_payload(events: events))

      assert_equal "applied", batch.status
      entry = @source.account.entries.sole
      assert_equal expected_date, entry.date
      assert_equal "booked", @source.financekit_transactions.sole.status
      assert_not entry.transaction.pending?
    end
  end

  test "pending transactions settle without posted_at while preserving identity and transacted date" do
    events = financekit_events
    transaction = events.last.fetch("transaction")
    transaction["status"] = "pending"
    transaction.delete("posted_at")
    first = accept_and_apply(financekit_payload(events: events))
    entry = @source.account.entries.sole
    assert entry.transaction.pending?
    assert_equal Date.new(2026, 8, 31), entry.date

    transaction["status"] = "booked"
    accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest, events: events))

    assert_equal entry.id, @source.account.entries.sole.id
    assert_equal Date.new(2026, 8, 31), entry.reload.date
    assert_not entry.transaction.reload.pending?
  end

  test "a malformed event rejects the whole batch before it enters the inbox" do
    events = financekit_events
    events.last.fetch("transaction")["amount"]["amount"] = 12.34
    payload = financekit_payload(events: events)

    assert_no_difference "FinancekitBatch.count" do
      error = assert_raises(Financekit::Error) { accept_batch(payload) }
      assert_equal "invalid_payload", error.code
    end
    assert_empty @source.account.entries
  end

  test "imports never claim an ambiguous manual transaction" do
    account = @source.account
    manual = account.entries.create!(amount: "12.34", currency: "USD", date: Date.new(2026, 9, 1),
      name: "Manual purchase", entryable: Transaction.new)

    accept_and_apply

    assert_equal 2, account.entries.count
    assert_nil manual.reload.external_id
  end

  test "same source identity moves pending to booked without replacing user edits" do
    pending_events = financekit_events
    pending = pending_events.last.fetch("transaction")
    pending["status"] = "pending"
    pending.delete("posted_at")
    first = accept_and_apply(financekit_payload(events: pending_events))
    entry = @source.account.entries.sole
    entry.update!(name: "My edited purchase", user_modified: true)

    accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest))

    assert_equal "My edited purchase", entry.reload.name
    assert_not entry.transaction.reload.pending?
    assert_equal 1, @source.account.entries.count
  end

  test "explicit tombstones retract only provider-owned entries and prevent resurrection" do
    first = accept_and_apply
    tombstone = {
      "kind" => "transaction_tombstone",
      "tombstone" => {
        "source_id" => @transaction_id,
        "source_account_id" => @source_id,
        "lineage_id" => @source.financekit_account_lineage_id,
        "mapping_version" => @source.mapping_version
      }
    }
    second = accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest,
      events: [ tombstone ]))

    assert_empty @source.account.entries.reload
    assert @source.financekit_transactions.sole.tombstoned_at?

    third = accept_and_apply(financekit_payload(sequence: 3, predecessor_digest: second.payload_digest,
      events: [ financekit_events.last ]))
    assert_empty @source.account.entries.reload
    assert_equal 1, third.counts.fetch("review_required")
    assert_equal "source_reappeared", @item.financekit_conflicts.sole.kind
  end

  test "reconciled entries retain ledger fields and produce a conflict on upsert" do
    first = accept_and_apply
    entry = @source.account.entries.sole
    entry.mark_reconciled!
    original = entry.attributes.slice("amount", "date", "name", "reconciled_at")
    event = financekit_events.last
    event["transaction"]["amount"] = money("99.00")
    event["transaction"]["posted_at"] = "2026-09-02T12:00:00Z"
    event["transaction"]["merchant_name"] = "Changed shop"

    batch = accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest, events: [ event ]))

    assert_equal original, entry.reload.attributes.slice(*original.keys)
    assert_equal 1, batch.counts.fetch("review_required")
    assert_equal "protected_entry", @item.financekit_conflicts.sole.kind
  end

  test "attribute locks protect entries even without user_modified" do
    first = accept_and_apply
    entry = @source.account.entries.sole
    entry.lock_attr!(:amount)
    assert_not entry.user_modified?
    event = financekit_events.last
    event["transaction"]["amount"] = money("99.00")

    accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest, events: [ event ]))

    assert_equal BigDecimal("12.34"), entry.reload.amount
    assert_equal "protected_entry", @item.financekit_conflicts.sole.kind
  end

  test "transfer pairs are protected from upserts and tombstones" do
    first = accept_and_apply
    entry = @source.account.entries.sole
    other_account = @family.accounts.create!(name: "Transfer destination", balance: 0, currency: "USD",
      accountable: Depository.new(subtype: "checking"))
    other = other_account.entries.create!(name: "Transfer in", amount: -entry.amount, currency: entry.currency,
      date: entry.date, entryable: Transaction.new)
    transfer = Transfer.create!(inflow_transaction: other.transaction, outflow_transaction: entry.transaction)
    event = financekit_events.last
    event["transaction"]["amount"] = money("99.00")
    second = accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest, events: [ event ]))
    tombstone = { "kind" => "transaction_tombstone",
      "tombstone" => event["transaction"].slice("source_id", "source_account_id", "lineage_id", "mapping_version") }

    accept_and_apply(financekit_payload(sequence: 3, predecessor_digest: second.payload_digest, events: [ tombstone ]))

    assert_equal BigDecimal("12.34"), entry.reload.amount
    assert Transfer.exists?(transfer.id)
    assert_equal %w[protected_entry protected_tombstone], @item.financekit_conflicts.order(:kind).pluck(:kind)
  end

  test "an edited pending entry still settles while its conflict awaits review" do
    event = financekit_events.last
    event["transaction"]["status"] = "pending"
    event["transaction"].delete("posted_at")
    first = accept_and_apply(financekit_payload(events: [ event ]))
    entry = @source.account.entries.sole
    entry.update!(name: "User name", user_modified: true)
    second = accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest, events: [ event ]))
    assert @source.financekit_transactions.sole.review_required?

    accept_and_apply(financekit_payload(sequence: 3, predecessor_digest: second.payload_digest, events: [ financekit_events.last ]))

    assert_equal "User name", entry.reload.name
    assert_not entry.transaction.reload.pending?
    assert_equal 1, @item.financekit_conflicts.open.count
  end

  test "retry after repair permits an unlocked transaction to import again" do
    first = accept_and_apply
    entry = @source.account.entries.sole
    entry.update!(import_locked: true)
    event = financekit_events.last
    event["transaction"]["amount"] = money("99.00")
    accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest, events: [ event ]))
    conflict = @item.financekit_conflicts.sole

    entry.unlock_for_sync!
    conflict.resolve!(user: @user, resolution: "retry_after_repair")
    assert_equal "repair_required", @item.reload.status
    @item.repair!
    batch = accept_and_apply(financekit_payload(events: [ event ]))

    assert_equal BigDecimal("99.00"), entry.reload.amount
    assert_equal 1, batch.counts.fetch("upserted")
    assert_not @source.financekit_transactions.sole.review_required?
    assert_empty @item.financekit_conflicts.open
  end

  test "conflicting balance observation reuse preserves the stored and canonical money" do
    first = accept_and_apply
    event = financekit_events.find { |record| record["kind"] == "balance_upsert" }
    event["balance"]["money"] = money("999.00", "credit")

    second = accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest,
      events: [ event ]))

    # The stored observation is immutable and the canonical balance is untouched,
    # but the disagreement is a conflict for the family, not a protocol failure:
    # fencing here would clear a credential only a foreground repair can reissue.
    assert_equal "applied", second.status
    assert_equal 1, second.counts.fetch("review_required")
    assert_equal BigDecimal("112.66"), @source.account.reload.balance
    assert_equal BigDecimal("112.66"), @source.financekit_balance_observations.sole.amount
    conflict = @item.financekit_conflicts.sole
    assert_equal "balance_observation_conflict", conflict.kind
    assert_equal @balance_id, conflict.details.fetch("source_id")
    assert_equal "active", @item.reload.status
    assert @item.authenticate_credential?(@credential)
  end

  test "a repeated balance disagreement does not pile up open conflicts" do
    first = accept_and_apply
    event = financekit_events.find { |record| record["kind"] == "balance_upsert" }
    event["balance"]["money"] = money("999.00", "credit")
    second = accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest,
      events: [ event ]))
    accept_and_apply(financekit_payload(sequence: 3, predecessor_digest: second.payload_digest,
      events: [ event ]))

    assert_equal 1, @item.financekit_conflicts.open.count
    assert_equal "active", @item.reload.status
  end

  test "a balance decision the family keeps is not reopened by an identical replay" do
    first = accept_and_apply
    disagreement = financekit_events.find { |record| record["kind"] == "balance_upsert" }
    disagreement["balance"]["money"] = money("999.00", "credit")
    second = accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest,
      events: [ disagreement ]))
    @item.financekit_conflicts.open.sole.resolve!(user: @user, resolution: "keep_sure")

    third = accept_and_apply(financekit_payload(sequence: 3, predecessor_digest: second.payload_digest,
      events: [ disagreement ]))

    assert_empty @item.financekit_conflicts.open
    assert_equal 1, @item.financekit_conflicts.count
    assert_equal 1, third.counts.fetch("settled")
    assert_equal BigDecimal("112.66"), @source.account.reload.balance
  end

  test "a balance decision survives replacing the publishing device" do
    first = accept_and_apply
    disagreement = financekit_events.find { |record| record["kind"] == "balance_upsert" }
    disagreement["balance"]["money"] = money("999.00", "credit")
    accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest,
      events: [ disagreement ]))
    @item.financekit_conflicts.open.sole.resolve!(user: @user, resolution: "keep_sure")
    account = @source.account
    lineage = @source.financekit_account_lineage

    enrollment = @enrollment.deep_dup
    enrollment["enrollment_id"] = SecureRandom.uuid
    enrollment["replaces_connection_id"] = @item.id
    replacement = Financekit::Enrollment.create!(@user, enrollment).item
    @source = FinancekitAccount.map!(replacement, @source_id,
      @mapping_input.except("booked_balance", "observed_at").merge(
        "action" => "link", "account_id" => account.id, "lineage_id" => lineage.id))
    replacement.activate!

    # Rebuilt so it carries the replacement's mapping_version; the observation
    # identity is unchanged because the clock is frozen. The observation lives
    # on the lineage and outlives the publisher, so the decision must too.
    replayed = financekit_events.find { |record| record["kind"] == "balance_upsert" }
    replayed["balance"]["money"] = money("999.00", "credit")
    batch = accept_and_apply(financekit_payload(item: replacement, events: [ replayed ]),
      item: replacement)

    assert_empty FinancekitConflict.where(family: @family).open
    assert_equal 1, batch.counts.fetch("settled")
  end

  test "one lineage keeps one open balance question when two publishers race" do
    first = accept_and_apply
    disagreement = financekit_events.find { |record| record["kind"] == "balance_upsert" }
    disagreement["balance"]["money"] = money("999.00", "credit")
    accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest,
      events: [ disagreement ]))
    raised = @item.financekit_conflicts.open.sole

    # A replacement device keeps the lineage of the device it replaces, so both
    # connections can look for an open question, find none, and then both
    # insert. Checking first cannot settle that; the index has to.
    enrollment = @enrollment.deep_dup
    enrollment["enrollment_id"] = SecureRandom.uuid
    enrollment["replaces_connection_id"] = @item.id
    replacement = Financekit::Enrollment.create!(@user, enrollment).item

    assert_raises(ActiveRecord::RecordNotUnique) do
      replacement.financekit_conflicts.create!(family: @family,
        financekit_account_lineage: raised.financekit_account_lineage,
        kind: "balance_observation_conflict", status: "open", details: raised.details)
    end
    assert_equal 1, FinancekitConflict.where(family: @family).open.count
  end

  test "losing the race for a balance question still applies the rest of the capture" do
    first = accept_and_apply
    disagreement = financekit_events.find { |record| record["kind"] == "balance_upsert" }
    disagreement["balance"]["money"] = money("999.00", "credit")
    # Stands in for the other publisher inserting between the check and this
    # insert: the question is open either way, so the import carries on rather
    # than failing the batch and spending an attempt.
    FinancekitConflict.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique.new("duplicate key"))

    second = accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest,
      events: [ disagreement ]))

    assert_equal "applied", second.status
    assert_equal 1, second.counts.fetch("review_required")
    assert_equal "active", @item.reload.status
    assert_equal BigDecimal("112.66"), @source.account.reload.balance
  end

  test "a balance decision matches an equivalent timestamp in another format" do
    first = accept_and_apply
    disagreement = financekit_events.find { |record| record["kind"] == "balance_upsert" }
    disagreement["balance"]["money"] = money("999.00", "credit")
    disagreement["balance"]["observed_at"] = "2026-09-10T12:00:00Z"
    second = accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest,
      events: [ disagreement ]))
    @item.financekit_conflicts.open.sole.resolve!(user: @user, resolution: "keep_sure")

    # Same instant, different spelling: it resolves to one stored observation,
    # so it has to resolve to one decision.
    reformatted = disagreement.deep_dup
    reformatted["balance"]["observed_at"] = "2026-09-10T12:00:00.000Z"
    accept_and_apply(financekit_payload(sequence: 3, predecessor_digest: second.payload_digest,
      events: [ reformatted ]))

    assert_empty @item.financekit_conflicts.open
    assert_equal 1, @item.financekit_conflicts.count
  end

  test "a settled balance decision does not suppress a different disagreement" do
    first = accept_and_apply
    disagreement = financekit_events.find { |record| record["kind"] == "balance_upsert" }
    disagreement["balance"]["money"] = money("999.00", "credit")
    second = accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest,
      events: [ disagreement ]))
    @item.financekit_conflicts.open.sole.resolve!(user: @user, resolution: "keep_sure")

    other = financekit_events.find { |record| record["kind"] == "balance_upsert" }
    other["balance"]["observed_at"] = 1.minute.from_now.iso8601
    other["balance"]["money"] = money("222.00", "credit")
    accept_and_apply(financekit_payload(sequence: 3, predecessor_digest: second.payload_digest,
      events: [ other ], captured_at: 1.minute.from_now.iso8601))
    accept_and_apply(financekit_payload(sequence: 4, predecessor_digest: FinancekitBatch.order(:sequence).last.payload_digest,
      events: [ other.deep_dup.tap { |event| event["balance"]["money"] = money("333.00", "credit") } ],
      captured_at: 1.minute.from_now.iso8601))

    assert_equal 1, @item.financekit_conflicts.open.count
  end

  test "retry after repair releases the observation blocking the replay" do
    first = accept_and_apply
    disagreement = financekit_events.find { |record| record["kind"] == "balance_upsert" }
    disagreement["balance"]["money"] = money("999.00", "credit")
    accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest,
      events: [ disagreement ]))

    # An immutable observation would disagree again after the repair, so the
    # retry only means something once the declined one is out of the way.
    @item.financekit_conflicts.open.sole.resolve!(user: @user, resolution: "retry_after_repair")

    assert_equal "repair_required", @item.reload.status
    assert_empty @source.financekit_balance_observations.where(source_id: @balance_id, kind: "booked")
  end

  test "a tombstone leaves review open while another conflict is unresolved" do
    accept_and_apply
    entry = @source.account.entries.sole
    entry.update!(locked_attributes: { "name" => Time.current.iso8601 })
    identity = @source.financekit_transactions.sole
    tombstone = {
      "kind" => "transaction_tombstone",
      "tombstone" => {
        "source_id" => @transaction_id,
        "source_account_id" => @source_id,
        "lineage_id" => @source.financekit_account_lineage_id,
        "mapping_version" => @source.mapping_version
      }
    }
    upsert = accept_and_apply(financekit_payload(sequence: 2,
      predecessor_digest: FinancekitBatch.order(:sequence).last.payload_digest,
      events: [ financekit_events.last ]))
    retraction = accept_and_apply(financekit_payload(sequence: 3, predecessor_digest: upsert.payload_digest,
      events: [ tombstone ]))
    identity.financekit_conflicts.open.find_by!(kind: "protected_entry")
      .resolve!(user: @user, resolution: "keep_sure")

    accept_and_apply(financekit_payload(sequence: 4, predecessor_digest: retraction.payload_digest,
      events: [ tombstone ]))

    assert_equal [ "protected_tombstone" ], identity.financekit_conflicts.open.pluck(:kind)
    assert identity.reload.review_required, "review must stay open while a conflict about the record is"
    assert_equal 1, @source.account.entries.reload.count
  end

  test "a source identifier outside the v1-v5 range is accepted" do
    uuidv7 = "01890a5d-ac96-774b-bcce-b302099a8057"
    event = financekit_events.last
    event.fetch("transaction")["source_id"] = uuidv7

    batch = accept_and_apply(financekit_payload(events: [ event ]))

    assert_equal "applied", batch.status
    assert_equal uuidv7, @source.financekit_transactions.sole.source_id
  end

  test "a second wallet account cannot map onto an already mapped canonical account" do
    other_source = SecureRandom.uuid
    @item.update!(status: "repair_required", consent: @item.consent.merge(
      "selected_source_account_ids" => [ @source_id, other_source ]))

    error = assert_raises(Financekit::Error) do
      FinancekitAccount.map!(@item, other_source, @mapping_input.except("booked_balance", "observed_at").merge(
        "action" => "link", "account_id" => @source.account.id))
    end

    assert_equal "lineage_account_conflict", error.code
    assert_equal 409, error.status
  end

  test "a conflict resolved with keep_sure is not reopened by later captures" do
    first = accept_and_apply
    tombstone = {
      "kind" => "transaction_tombstone",
      "tombstone" => {
        "source_id" => @transaction_id,
        "source_account_id" => @source_id,
        "lineage_id" => @source.financekit_account_lineage_id,
        "mapping_version" => @source.mapping_version
      }
    }
    second = accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest,
      events: [ tombstone ]))
    third = accept_and_apply(financekit_payload(sequence: 3, predecessor_digest: second.payload_digest,
      events: [ financekit_events.last ]))
    conflict = @item.financekit_conflicts.sole
    conflict.resolve!(user: @user, resolution: "keep_sure")

    fourth = accept_and_apply(financekit_payload(sequence: 4, predecessor_digest: third.payload_digest,
      events: [ financekit_events.last ]))

    assert_equal 1, @item.financekit_conflicts.count
    assert_equal "resolved", conflict.reload.status
    assert_equal 1, fourth.counts.fetch("settled")
    assert_empty @source.account.entries.reload
    assert_not @source.financekit_transactions.sole.review_required?
  end

  test "a replacement identity awaiting review is not imported by the next capture" do
    accept_and_apply
    account = @source.account
    lineage = @source.financekit_account_lineage

    replacement_enrollment = @enrollment.deep_dup
    replacement_enrollment["enrollment_id"] = SecureRandom.uuid
    replacement_enrollment["replaces_connection_id"] = @item.id
    replacement = Financekit::Enrollment.create!(@user, replacement_enrollment).item
    @source = FinancekitAccount.map!(replacement, @source_id,
      @mapping_input.except("booked_balance", "observed_at").merge(
        "action" => "link", "account_id" => account.id, "lineage_id" => lineage.id))
    replacement.activate!

    unknown_identity = financekit_events.last
    unknown_identity.fetch("transaction")["source_id"] = SecureRandom.uuid
    first = accept_and_apply(financekit_payload(item: replacement, events: [ unknown_identity ]),
      item: replacement)

    assert_equal 1, first.counts.fetch("review_required")
    assert_equal "replacement_identity", replacement.financekit_conflicts.sole.kind
    assert_equal 1, account.entries.reload.count

    second = accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest,
      item: replacement, events: [ unknown_identity ]), item: replacement)

    assert_equal 1, second.counts.fetch("review_required")
    assert_equal 1, account.entries.reload.count
    assert_equal 1, replacement.financekit_conflicts.count

    replacement.financekit_conflicts.sole.resolve!(user: @user, resolution: "retry_after_repair")
    replacement.repair!
    repaired = accept_and_apply(financekit_payload(item: replacement, events: [ unknown_identity ]), item: replacement)

    assert_equal 1, repaired.counts.fetch("upserted")
    assert_equal 2, account.entries.reload.count
    assert_empty replacement.financekit_conflicts.open
  end

  test "balance observations are retained while only the latest booked value is materialized" do
    first = accept_and_apply
    second_events = financekit_events.select { |event| event["kind"] == "balance_upsert" }
    second_balance = second_events.sole.fetch("balance")
    second_balance["source_id"] = SecureRandom.uuid
    second_balance["observed_at"] = 1.minute.from_now.iso8601
    second_balance["money"] = money("111.25", "credit")

    accept_and_apply(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest,
      events: second_events, captured_at: 1.minute.from_now.iso8601))

    assert_equal 2, @source.financekit_balance_observations.count
    assert_equal BigDecimal("111.25"), @source.account.reload.balance
  end
end
