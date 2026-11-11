require "test_helper"

class RecurringTransaction::ReferenceDiagnosticsTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @family.recurring_transactions.destroy_all
    @series = create_series(name: "CITY WATER", amount: 80, hints: { "bank_reference" => "VN 4711" })
    @occurrence = @series.recurring_occurrences.order(:due_on).first
  end

  test "an entry that would link says so, by series id or by reference" do
    entry = create_entry(amount: 70, notes: "VN 4711 Abschlag")

    by_id = rows_for(@series.id)
    by_reference = rows_for("vn  4711")

    assert_equal [ entry.id ], by_id.map(&:entry_id)
    assert_equal [ entry.id ], by_reference.map(&:entry_id)
    assert_match(/would link \(exact, score/, by_id.sole.verdict)
  end

  test "entries without the reference in the note are not listed" do
    create_entry(amount: 70, notes: "something else")

    assert_empty rows_for(@series.id)
  end

  test "an already linked entry is reported with its occurrence" do
    entry = create_entry(amount: 70, notes: "VN 4711")
    RecurringTransaction::Matcher.new(@family).run!

    row = rows_for(@series.id).sole

    assert_equal entry.id, row.entry_id
    assert_match(/linked \(confirmed\)/, row.verdict)
  end

  test "a rejected pair is reported" do
    entry = create_entry(amount: 70, notes: "VN 4711")
    RecurringMatchRejection.create!(recurring_transaction: @series, entry: entry)

    assert_match(/rejected by the user/, rows_for(@series.id).sole.verdict)
  end

  test "a stale suggestion is reported" do
    entry = create_entry(amount: 70, notes: "VN 4711")
    @occurrence.allocations.create!(entry: entry, allocated_amount: 70, currency: "USD", source_amount: 70, source_currency: "USD",
                                    state: "suggested", source: "auto_matched", match_confidence: 0.7, match_signals: {}, paid_on: entry.date)

    verdict = rows_for(@series.id).sole.verdict

    assert_match(/suggested allocation/, verdict)
  end

  test "the date window does not apply to a reference payment" do
    create_entry(amount: 70, notes: "VN 4711", date: Date.current - 20)

    verdict = rows_for(@series.id).sole.verdict

    assert_match(/would link/, verdict)
    assert_no_match(/window/, verdict)
  end

  test "a payment long before the first cycle is reported as such" do
    create_entry(amount: 70, notes: "VN 4711", date: Date.current - 400)

    assert_match(/before the first cycle/, rows_for(@series.id, months: 24).sole.verdict)
  end

  test "a wrong account is reported" do
    accounts(:credit_card).entries.create!(date: Date.current, amount: 70, currency: "USD", name: "x", notes: "VN 4711", entryable: Transaction.new)

    assert_match(/account/, rows_for(@series.id).sole.verdict)
  end

  test "a transfer leg is reported" do
    entry = create_entry(amount: 70, notes: "VN 4711")
    entry.entryable.update!(kind: "funds_movement")

    assert_match(/transfer/, rows_for(@series.id).sole.verdict)
  end

  test "a pending entry is reported as suggestion-only" do
    create_entry(amount: 70, notes: "VN 4711", extra: { "simplefin" => { "pending" => true } })

    assert_match(/pending/, rows_for(@series.id).sole.verdict)
  end

  test "another bill with the same reference is reported as a tie" do
    create_series(name: "OTHER", amount: 80, dedup_scope: "b", hints: { "bank_reference" => "VN 4711" })
    create_entry(amount: 80, notes: "VN 4711")

    assert_match(/ambiguous/, rows_for(@series.id).sole.verdict)
  end

  test "diagnosing writes nothing" do
    create_entry(amount: 70, notes: "VN 4711")
    snapshot = -> { [ RecurringAllocation.count, RecurringOccurrence.pluck(:id, :status, :updated_at), RecurringTransaction.pluck(:id, :updated_at) ] }
    before = snapshot.call

    rows_for(@series.id)
    RecurringTransaction::ReferenceDiagnostics.new(@family, @series.id).report

    assert_equal before, snapshot.call
  end

  test "the report is printable lines" do
    create_entry(amount: 70, notes: "VN 4711")

    lines = RecurringTransaction::ReferenceDiagnostics.new(@family, @series.id).report

    assert_kind_of Array, lines
    assert_match(/vn 4711/, lines.join("\n"))
    assert_match(/would link/, lines.join("\n"))
  end

  test "an unknown series or reference raises a clear error" do
    assert_raises(ArgumentError) { RecurringTransaction::ReferenceDiagnostics.new(@family, "no-such-reference").rows }
  end

  test "rival bills sharing a reference make a payment outside both windows ambiguous" do
    create_series(name: "Water twin", amount: 80, dedup_scope: "twin", hints: { "bank_reference" => "VN 4711" })
    create_entry(amount: 70, notes: "VN 4711", date: Date.current - 20)

    assert_match(/ambiguous with Water twin/, rows_for(@series.id).sole.verdict)
  end

  test "a transfer series with the reference only on the receiving leg lists the outflow" do
    transfer_series = @family.recurring_transactions.create!(
      name: "Allowance", account: @account, destination_account: accounts(:loan), amount: 250, currency: "USD", bill_type: "transfer",
      expected_day_of_month: Date.current.day, anchor_date: Date.current, last_occurrence_date: Date.current,
      next_expected_date: Date.current, status: "active", manual: true, matcher_hints: { "bank_reference" => "ALLOW 77" }
    )
    outflow = @account.entries.create!(date: Date.current, amount: 250, currency: "USD", name: "Transfer", entryable: Transaction.new(kind: "funds_movement"))
    inflow = accounts(:loan).entries.create!(date: Date.current, amount: -250, currency: "USD", name: "Transfer", notes: "ALLOW 77",
                                             entryable: Transaction.new(kind: "funds_movement"))
    Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable, status: "confirmed")

    assert_includes rows_for(transfer_series.id).map(&:entry_id), outflow.id
  end

  test "bills with the same name and different references list payments carrying either reference" do
    other = create_series(name: "CITY WATER", amount: 80, dedup_scope: "other", hints: { "bank_reference" => "VN 9999" })
    first = create_entry(amount: 70, notes: "VN 4711")
    second = create_entry(amount: 70, notes: "VN 9999")

    rows = RecurringTransaction::ReferenceDiagnostics.new(@family, "city water").rows

    assert_includes rows.map(&:entry_id), first.id
    assert_includes rows.map(&:entry_id), second.id
    assert other.present?
  end

  test "a rival the user rejected for the payment does not make it ambiguous" do
    rival = create_series(name: "Water twin", amount: 80, dedup_scope: "twin", hints: { "bank_reference" => "VN 4711" })
    entry = create_entry(amount: 70, notes: "VN 4711")
    RecurringMatchRejection.create!(recurring_transaction: rival, entry: entry)

    assert_no_match(/ambiguous/, rows_for(@series.id).sole.verdict)
  end

  test "a paused bill with identical open cycles still makes the payment ambiguous" do
    twin = create_series(name: "Water twin", amount: 80, dedup_scope: "twin", hints: { "bank_reference" => "VN 4711" })
    twin.update_columns(status: "inactive")
    create_entry(amount: 70, notes: "VN 4711")

    assert_match(/ambiguous with Water twin/, rows_for(@series.id).sole.verdict)
  end

  test "a future-dated entry is not reported" do
    create_entry(amount: 70, notes: "VN 4711", date: Date.current + 5)

    assert_empty rows_for(@series.id)
  end

  test "a paused bill keeps its confirmed link in the report" do
    entry = create_entry(amount: 70, notes: "VN 4711")
    RecurringTransaction::Matcher.new(@family).run!
    @series.update_columns(status: "inactive")

    assert_match(/linked \(confirmed\)/, rows_for(@series.id).sole.verdict)
  end

  test "a rival that scores clearly higher is reported as taking the payment, not as a tie" do
    weak = create_series(name: "Water far", amount: 80, dedup_scope: "far", hints: { "bank_reference" => "VN 4711" }, offset: 12)
    create_series(name: "Water exact", amount: 80, dedup_scope: "exact", hints: { "bank_reference" => "VN 4711" })
    create_entry(amount: 80, notes: "VN 4711", date: Date.current)

    verdict = rows_for(weak.id).sole.verdict

    assert_match(/another bill matches better \(.*Water exact/, verdict)
  end

  private
    def rows_for(argument, months: 12)
      RecurringTransaction::ReferenceDiagnostics.new(@family, argument, months: months).rows
    end

    def create_series(name:, amount:, dedup_scope: "", hints: {}, offset: 0)
      due = Date.current + offset
      @family.recurring_transactions.create!(
        name: name, account: @account, amount: amount, currency: "USD", bill_type: "bill", dedup_scope: dedup_scope,
        expected_day_of_month: due.day, anchor_date: due, last_occurrence_date: due,
        next_expected_date: due, status: "active", manual: true, matcher_hints: hints
      )
    end

    def create_entry(amount:, notes:, date: Date.current, extra: {})
      @account.entries.create!(date: date, amount: amount, currency: "USD", name: "CITY WATER", notes: notes,
                               entryable: Transaction.new(extra: extra))
    end
end
