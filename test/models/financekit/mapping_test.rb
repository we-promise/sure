require "test_helper"
require_relative "../../support/financekit_test_helper"

class Financekit::MappingTest < ActiveSupport::TestCase
  include FinancekitTestHelper
  setup { financekit_setup }

  test "lossless signs include refunds payments zero and large magnitudes" do
    %w[0 1 1.234 999999999999999.9999].each do |amount|
      assert_equal BigDecimal(amount), Financekit::Mapping.transaction_amount(money(amount, "debit"))
      assert_equal -BigDecimal(amount), Financekit::Mapping.transaction_amount(money(amount, "credit"))
    end
    assert_equal BigDecimal("42"), Financekit::Mapping.balance(money("42", "credit"), "Depository")
    assert_equal BigDecimal("42"), Financekit::Mapping.balance(money("42", "debit"), "CreditCard")
    assert_equal -BigDecimal("42"), Financekit::Mapping.balance(money("42", "credit"), "CreditCard")
    assert_equal -BigDecimal("42"), Financekit::Mapping.balance(money("42", "debit"), "Depository")
    assert_equal BigDecimal("100"), Financekit::Payload.money!(money("100", "debit", "JPY"))
    assert_equal BigDecimal("1.234"), Financekit::Payload.money!(money("1.234", "debit", "KWD"))
  end

  test "ledger date uses the confirmed account timezone at month boundary" do
    record = { "transacted_at" => "2026-03-01T00:30:00Z" }
    assert_equal Date.new(2026, 2, 28), Financekit::Mapping.ledger_date(record, "America/Los_Angeles")
    record["posted_at"] = "2026-03-01T08:30:00Z"
    assert_equal Date.new(2026, 3, 1), Financekit::Mapping.ledger_date(record, "America/Los_Angeles")
  end

  test "floats negative magnitudes precision overflow and currency defaults are rejected" do
    [ 1.23, "-1", "NaN", "1e2", "1.12345", "1000000000000000" ].each do |amount|
      assert_raises(Financekit::Error) { Financekit::Payload.money!(money(amount)) }
    end
    assert_raises(Financekit::Error) { Financekit::Payload.money!(money("1", "debit", "NOPE")) }
    assert_raises(Financekit::Error) { Financekit::Payload.money!(money.except("currency")) }
  end

  test "identity-only imports never claim an ambiguous manual transaction" do
    account = @source.account
    manual = account.entries.create!(amount: "12.34", currency: "USD", date: Date.new(2026, 9, 1),
      name: "Manual purchase", entryable: Transaction.new)
    FinancekitBatch.accept!(@item, financekit_envelope)
    assert Financekit::Processor.new(@item).apply_next!
    assert_equal 2, account.entries.count
    assert_nil manual.reload.external_id
  end

  test "same ID pending to booked preserves user edits while clearing pending" do
    data = financekit_payload
    data["transactions"].first["status"] = "pending"
    first = FinancekitBatch.accept!(@item, financekit_envelope(data))
    Financekit::Processor.new(@item).apply_next!
    entry = @source.account.entries.sole
    entry.update!(name: "My edited purchase", user_modified: true)
    assert entry.transaction.pending?
    FinancekitBatch.accept!(@item, financekit_envelope(sequence: 2, previous: first.digest))
    assert Financekit::Processor.new(@item).apply_next!
    assert_equal "My edited purchase", entry.reload.name
    assert_not entry.transaction.reload.pending?
    assert_equal 1, @source.account.entries.count
  end

  test "changed pending ID creates separate identity without automatic merge" do
    data = financekit_payload
    data["transactions"].first["status"] = "pending"
    first = FinancekitBatch.accept!(@item, financekit_envelope(data))
    Financekit::Processor.new(@item).apply_next!
    data = financekit_payload
    data["transactions"].first["source_id"] = SecureRandom.uuid
    FinancekitBatch.accept!(@item, financekit_envelope(data, sequence: 2, previous: first.digest))
    Financekit::Processor.new(@item).apply_next!
    assert_equal 2, @source.account.entries.count
  end

  test "tombstones retract only unprotected provider owned entries and cannot resurrect" do
    first = FinancekitBatch.accept!(@item, financekit_envelope)
    Financekit::Processor.new(@item).apply_next!
    tombstone = financekit_payload
    tombstone["transactions"] = []
    tombstone["tombstones"] = [ { "source_id" => @transaction_id, "account_id" => @source_id, "mapping_version" => 1 } ]
    second = FinancekitBatch.accept!(@item, financekit_envelope(tombstone, sequence: 2, previous: first.digest))
    Financekit::Processor.new(@item).apply_next!
    assert_equal 0, @source.account.entries.count
    assert_not_nil @source.financekit_transactions.sole.tombstoned_at
    third = FinancekitBatch.accept!(@item, financekit_envelope(sequence: 3, previous: second.digest))
    Financekit::Processor.new(@item).apply_next!
    assert_equal 0, @source.account.entries.count
    assert_equal 1, third.reload.counts["review_required"]
  end

  test "protected tombstone becomes review and missing snapshot records never delete" do
    first = FinancekitBatch.accept!(@item, financekit_envelope)
    Financekit::Processor.new(@item).apply_next!
    @source.account.entries.sole.update!(import_locked: true)
    data = financekit_payload
    data["transactions"] = []
    data["tombstones"] = [ { "source_id" => @transaction_id, "account_id" => @source_id, "mapping_version" => 1 } ]
    second = FinancekitBatch.accept!(@item, financekit_envelope(data, sequence: 2, previous: first.digest))
    Financekit::Processor.new(@item).apply_next!
    assert_equal 1, @source.account.entries.count
    assert_equal 1, second.reload.counts["review_required"]
    data["tombstones"] = []
    FinancekitBatch.accept!(@item, financekit_envelope(data, sequence: 3, previous: second.digest))
    Financekit::Processor.new(@item).apply_next!
    assert_equal 1, @source.account.entries.count
  end

  test "available credit cannot overwrite a booked balance" do
    data = financekit_payload
    data["accounts"].first.delete("booked_balance")
    data["transactions"] = []
    FinancekitBatch.accept!(@item, financekit_envelope(data))
    Financekit::Processor.new(@item).apply_next!
    assert_equal BigDecimal("125.00"), @source.account.reload.balance
    assert_equal "100.32", @source.reload.available_balance["amount"]
  end

  test "initial booked balance observation fences older balance uploads" do
    assert_equal "125.00", @source.booked_balance.fetch("amount")
    data = financekit_payload
    data["accounts"].first["observed_at"] = 1.day.ago.iso8601
    batch = FinancekitBatch.accept!(@item, financekit_envelope(data))
    assert_not Financekit::Processor.new(@item).apply_next!
    assert_equal "stale_balance", batch.reload.error_code
    assert_equal BigDecimal("125.00"), @source.account.reload.balance
  end

  test "legacy provider links cannot be silently supplied by FinanceKit" do
    account = accounts(:depository)
    account.accountable.update!(subtype: "checking")
    account.update_column(:plaid_account_id, plaid_accounts(:one).id)
    input = @mapping_input.except("booked_balance", "observed_at").merge(
      "action" => "link", "account_id" => account.id,
      "currency" => account.currency, "subtype" => account.accountable.subtype)
    @source.destroy!
    error = assert_raises(Financekit::Error) { FinancekitAccount.map!(@item, @source_id, input) }
    assert_equal "account_already_supplied", error.code
  end

  test "new identity after reinstall requires explicit reconciliation" do
    assert_equal "identity_reconciliation_required", assert_raises(Financekit::Error) {
      @item.replace_device!({ "expected_generation" => 1, "device_public_key" => @device_jwk,
        "consent" => @enrollment["consent"], "continuity" => "unknown" })
    }.code
    assert_equal 1, @item.reload.generation
  end
end
