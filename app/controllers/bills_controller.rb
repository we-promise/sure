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
    @total_due = total_of(due_now)
    @due_count = due_now.size
    @needs_action_count = due_now.count { |bill| !bill.autopay? }

    # Every bill is monthly today, so the recurring commitment is simply their sum.
    # This needs normalising per cadence once bills can be weekly or annual.
    @monthly_total = total_of(bills)

    @duplicate_keys = bills.group_by(&:duplicate_key)
                           .select { |_key, group| group.size > 1 }
                           .keys
                           .to_set
  end

  private

    # Converted into the family currency rather than shown per currency, because the
    # question the headline answers is "how much do I owe", which is one number.
    #
    # A pair with no rate available is left out and counted instead of raising, so one
    # missing rate cannot take down the page or, worse, quietly understate the total
    # without saying so.
    def total_of(bills)
      return nil if bills.empty?

      target = Current.family.currency
      @unconvertible_count = 0

      bills.reduce(Money.new(0, target)) do |sum, bill|
        begin
          sum + bill.amount_money.exchange_to(target)
        rescue Money::ConversionError
          @unconvertible_count += 1
          sum
        end
      end
    end

    def ensure_recurring_enabled
      redirect_to root_path if Current.family.recurring_transactions_disabled?
    end
end
