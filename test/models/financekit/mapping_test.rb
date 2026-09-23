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
    second, = accept_batch(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest, events: [ event ]))

    assert_not Financekit::Processor.new(@item).apply_next!

    assert_equal "balance_observation_conflict", second.reload.error_code
    assert_equal "failed", second.status
    assert_equal BigDecimal("112.66"), @source.account.reload.balance
    assert_equal BigDecimal("112.66"), @source.financekit_balance_observations.sole.amount
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
