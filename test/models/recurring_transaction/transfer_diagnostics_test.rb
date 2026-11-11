require "test_helper"

class RecurringTransaction::TransferDiagnosticsTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @family.recurring_transactions.destroy_all
    @series = create_series(name: "Allowance", destination: accounts(:loan))
  end

  test "an outflow of the series' transfer would link, found by name without any reference" do
    entry = create_transfer(to: accounts(:loan))

    rows = RecurringTransaction::ReferenceDiagnostics.new(@family, "allowance").rows

    assert_equal [ entry.id ], rows.map(&:entry_id)
    assert_match(/would link \(exact/, rows.sole.verdict)
  end

  test "a transfer into another account names both destinations" do
    create_transfer(to: accounts(:credit_card))

    assert_match(/wrong destination: the transfer pays into .*, this series into /, verdict)
  end

  test "an entry that is no transfer says so" do
    @account.entries.create!(date: Date.current, amount: 250, currency: "USD", name: "plain", entryable: Transaction.new)

    assert_match(/not a transfer outflow/, verdict)
  end

  test "an outflow already confirmed to another series names that series" do
    entry = create_transfer(to: accounts(:loan))
    other = create_series(name: "Other plan", destination: accounts(:loan), dedup_scope: "other")
    other.recurring_occurrences.order(:due_on).first.allocations.create!(
      entry: entry, allocated_amount: 250, currency: "USD", state: "confirmed", source: "auto_matched", paid_on: entry.date
    )

    assert_match(/already confirmed to another bill \(Other plan\)/, verdict)
  end

  test "a rejected outflow is reported" do
    entry = create_transfer(to: accounts(:loan))
    RecurringMatchRejection.create!(recurring_transaction: @series, entry: entry)

    assert_match(/rejected by the user/, verdict)
  end

  test "an outflow outside the nearest cycle's window is reported with the window" do
    create_transfer(to: accounts(:loan), date: Date.current - 40)

    assert_match(/outside the window of the nearest cycle/, verdict)
  end

  test "a twin transfer series with the same accounts and amount makes the outflow ambiguous" do
    create_series(name: "Allowance twin", destination: accounts(:loan), dedup_scope: "twin")
    create_transfer(to: accounts(:loan))

    assert_match(/ambiguous with Allowance twin/, verdict)
  end

  test "an inactive series with open cycles is still diagnosed from them" do
    create_transfer(to: accounts(:loan))
    @series.update_columns(status: "inactive")

    assert_match(/would link/, verdict)
  end

  test "it writes nothing" do
    create_transfer(to: accounts(:loan))
    before = [ RecurringAllocation.count, RecurringOccurrence.count ]

    RecurringTransaction::ReferenceDiagnostics.new(@family, @series.id).report

    assert_equal before, [ RecurringAllocation.count, RecurringOccurrence.count ]
  end

  private
    def verdict
      RecurringTransaction::ReferenceDiagnostics.new(@family, @series.id).rows.sole.verdict
    end

    def create_series(name:, destination:, dedup_scope: "")
      series = @family.recurring_transactions.create!(
        name: name, account: @account, destination_account: destination, amount: 250, currency: "USD", bill_type: "transfer",
        dedup_scope: dedup_scope, expected_day_of_month: Date.current.day, anchor_date: Date.current,
        last_occurrence_date: Date.current, next_expected_date: Date.current, status: "active", manual: true
      )
      RecurringTransaction::OccurrenceGenerator.new(series).generate!
      series
    end

    def create_transfer(to:, date: Date.current)
      outflow = @account.entries.create!(date: date, amount: 250, currency: "USD", name: "Transfer", entryable: Transaction.new(kind: "funds_movement"))
      inflow = to.entries.create!(date: date, amount: -250, currency: "USD", name: "Transfer", entryable: Transaction.new(kind: "funds_movement"))
      Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable, status: "confirmed")
      outflow
    end
end
