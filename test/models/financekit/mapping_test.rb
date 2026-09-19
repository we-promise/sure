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
