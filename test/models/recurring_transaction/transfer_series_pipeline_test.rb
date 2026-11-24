require "test_helper"

class RecurringTransaction::TransferSeriesPipelineTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @destination = accounts(:loan)
    @family.recurring_transactions.destroy_all
  end

  test "a transfer series made by mark-as-recurring links every exact-day outflow through the whole pipeline, next to sibling transfer series" do
    travel_to Date.new(2026, 11, 3) do
      dates = [ Date.new(2026, 5, 1), Date.new(2026, 6, 1), Date.new(2026, 7, 2), Date.new(2026, 8, 3),
                Date.new(2026, 9, 2), Date.new(2026, 10, 1), Date.new(2026, 11, 3) ]
      transfers = dates.map { |date| create_transfer(amount: 250, date: date, to: @destination) }
      allowance = from_transfer(transfers.first, day: 3)

      shopping = dates.map { |date| create_transfer(amount: 500, date: date, to: accounts(:credit_card)) }
      from_transfer(shopping.first, day: 3)
      contracts = [ [ "Contract_1", accounts(:investment) ], [ "Contract_2", accounts(:property) ] ].map do |reference, to|
        paid = dates.map { |date| create_transfer(amount: 2000, date: date, to: to, notes: reference) }
        series = from_transfer(paid.first, day: 3)
        series.update!(matcher_hints: { "bank_reference" => reference, "reference_only" => true })
        series
      end

      RecurringTransaction::Pipeline.new(@family).run!
      RecurringTransaction::HistoryBackfiller.new(@family, months: 72).run!
      RecurringTransaction::Pipeline.new(@family).run!
      RecurringTransaction::Matcher.new(@family).run!

      linked = RecurringAllocation.where(entry_id: transfers.map(&:id)).count
      assert_equal dates.size, linked, "cycles: #{allowance.recurring_occurrences.order(:due_on).pluck(:due_on, :status).inspect}"
      assert_equal 0, allowance.recurring_occurrences.open_status.where("due_on < ?", Date.current).count
      assert_equal 14, contracts.sum { |series| series.recurring_occurrences.paid.count }
    end
  end

  private
    def from_transfer(outflow, day:)
      series = RecurringTransaction.create_from_transfer(Transfer.find_by!(outflow_transaction_id: outflow.entryable_id))
      series.update!(expected_day_of_month: day)
      series
    end

    def create_transfer(amount:, date:, to:, notes: nil)
      outflow = @account.entries.create!(date: date, amount: amount, currency: "USD", name: "Transfer to #{to.name}", notes: notes,
                                         entryable: Transaction.new(kind: "funds_movement"))
      inflow = to.entries.create!(date: date, amount: -amount, currency: "USD", name: "Transfer from #{@account.name}",
                                  entryable: Transaction.new(kind: "funds_movement"))
      Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable, status: "confirmed")
      outflow
    end
end
