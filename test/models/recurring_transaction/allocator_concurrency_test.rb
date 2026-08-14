require "test_helper"
require "concurrent"

# One transaction must never be allocated beyond its own amount, no matter how
# many occurrences want it at once. The occurrence row lock cannot enforce this
# on its own: allocations against two DIFFERENT occurrences take two different
# row locks and never meet, so both read the same stale capacity.
#
# Real threads on real connections, so this needs real commits.
class RecurringTransaction::AllocatorConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family  = Family.create!(name: "Allocator Race", currency: "USD")
    @account = Account.create!(
      family: @family, name: "Checking", currency: "USD",
      balance: 0, accountable: Depository.new)

    @entry = Entry.create!(
      account: @account, name: "One payment", date: Date.current,
      amount: 1000, currency: "USD", entryable: Transaction.new)

    @first  = occurrence_for("Rent")
    @second = occurrence_for("Storage")
  end

  teardown do
    RecurringAllocation.where(entry_id: @entry.id).delete_all
    RecurringOccurrence.where(family_id: @family.id).delete_all
    RecurringTransaction.where(family_id: @family.id).delete_all
    Entry.where(account_id: @account.id).delete_all
    @account.destroy
    @family.destroy
  end

  test "one entry cannot be allocated past its amount by concurrent writers" do
    latch = Concurrent::CountDownLatch.new(2)

    outcomes = [ @first, @second ].map do |occurrence|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          # Both threads reach the capacity read before either inserts, which
          # is the interleaving the row lock cannot prevent.
          latch.count_down
          latch.wait(5)
          RecurringTransaction::Allocator.new(occurrence).allocate!(entry: @entry, amount: 600)
          :allocated
        rescue RecurringTransaction::Allocator::OverAllocationError
          :rejected
        end
      end
    end.map(&:value)

    allocated = RecurringAllocation.where(entry_id: @entry.id).sum(:allocated_amount)

    assert_equal 600, allocated,
      "two 600 allocations of a 1000 transaction must not both survive (got #{allocated})"
    assert_includes outcomes, :rejected, "the second writer should have been rejected"
  end

  test "an exhausted entry allocates nothing rather than the occurrence balance" do
    RecurringTransaction::Allocator.new(@first).allocate!(entry: @entry, amount: 1000)

    assert_nil RecurringTransaction::Allocator.new(@second).allocate_matched!(
      entry: @entry, state: "confirmed", confidence: 0.9, signals: {})

    assert_equal 1000, RecurringAllocation.where(entry_id: @entry.id).sum(:allocated_amount)
  end

  private
    def occurrence_for(name)
      series = RecurringTransaction.create!(
        family: @family, account: @account, name: name, amount: 800,
        currency: "USD", expected_day_of_month: 9, status: "active",
        manual: true, bill_type: "bill",
        last_occurrence_date: Date.current, next_expected_date: Date.current)

      due = Date.current.beginning_of_month + 7
      RecurringOccurrence.find_or_create_by!(
        recurring_transaction: series, family: @family, original_due_on: due) do |row|
          row.due_on = due
          row.currency = "USD"
          row.expected_amount = 800
          row.status = "scheduled"
        end
    end
end
