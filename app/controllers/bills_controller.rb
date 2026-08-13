class BillsController < ApplicationController
  before_action :ensure_recurring_enabled

  # Bills are read straight off the table rather than through
  # `RecurringTransaction#projected_entry`, which returns nil for anything not in the
  # future. Every existing surface is a forecast, so an overdue bill is currently
  # invisible app-wide -- and "what have I not paid" is the whole question this page
  # exists to answer.
  def index
    # Sorted and grouped in Ruby rather than SQL because the due date has to be derived
    # (see RecurringTransaction#next_due_date), and a family's bill count is small.
    bills = Current.family.recurring_transactions
                   .accessible_by(Current.user)
                   .bills
                   .includes(:merchant)
                   .to_a
                   .sort_by(&:next_due_date)

    @overdue, upcoming = bills.partition(&:overdue?)
    @this_month, @later = upcoming.partition { |bill| bill.next_due_date <= Date.current.end_of_month }

    due_now = @overdue + @this_month
    @total_due, @unconvertible_count = total_of(due_now, &:amount_money)
    @due_count = due_now.size
    @needs_action_count = due_now.count { |bill| !bill.autopay? }

    # Normalized per cadence: a weekly bill counts ~4.3x its amount here, an
    # annual bill a twelfth. Summing raw amounts across mixed cadences would
    # answer no meaningful question.
    @monthly_total, _monthly_unconvertible = total_of(bills, &:monthly_equivalent_amount)

    @duplicate_keys = bills.group_by(&:duplicate_key)
                           .select { |_key, group| group.size > 1 }
                           .keys
                           .to_set

    # Matches the engine was not sure enough to link on its own. This queue
    # IS the pay-run page's business: every unreviewed suggestion is a bill
    # whose paid state is possibly wrong.
    @suggested_allocations = RecurringAllocation
                               .suggested
                               .joins(recurring_occurrence: :recurring_transaction)
                               .where(recurring_occurrences: { family_id: Current.family.id })
                               .merge(RecurringTransaction.accessible_by(Current.user))
                               .includes(:entry, recurring_occurrence: { recurring_transaction: :merchant })
                               .order(:created_at)
  end

  private

    # Converted into the family currency rather than shown per currency, because the
    # question the headline answers is "how much do I owe", which is one number.
    #
    # A pair with no rate available is left out and counted instead of raising, so one
    # missing rate cannot take down the page or, worse, quietly understate the total
    # without saying so. Returns [total, unconvertible_count] so each caller keeps its
    # own count -- an earlier version stored the count in an ivar that the second call
    # silently overwrote.
    def total_of(bills, &value_of)
      return [ nil, 0 ] if bills.empty?

      target = Current.family.currency
      unconvertible = 0

      total = bills.reduce(Money.new(0, target)) do |sum, bill|
        begin
          sum + value_of.call(bill).exchange_to(target)
        rescue Money::ConversionError
          unconvertible += 1
          sum
        end
      end

      [ total, unconvertible ]
    end

    def ensure_recurring_enabled
      redirect_to root_path if Current.family.recurring_transactions_disabled?
    end
end
