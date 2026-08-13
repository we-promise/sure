class BillsController < ApplicationController
  before_action :ensure_recurring_enabled

  # The pay-run workspace, built on occurrence rows rather than series
  # projections: every row is a specific obligation instance with a real due
  # date and a real payment state, which is what lets overdue and partially
  # paid render at all.
  def index
    @view = %w[all calendar paycheck].include?(params[:view]) ? params[:view] : "overview"

    case @view
    when "all"
      load_all_series
      render :all
      return
    when "calendar"
      load_calendar
      render :calendar
      return
    when "paycheck"
      @plan = RecurringTransaction::PaycheckPlanner.new(Current.family, user: Current.user).plan
      render :paycheck
      return
    end

    occurrences = payable_occurrences
    preload_allocation_sums(occurrences)

    today = Date.current
    month_end = today.end_of_month

    open_occurrences, closed = occurrences.partition(&:scheduled?)
    active_open, @dormant = open_occurrences.partition { |occurrence| occurrence.recurring_transaction.active? }

    @overdue, upcoming = active_open.partition { |occurrence| occurrence.derived_state == :overdue }
    this_month, later = upcoming.partition { |occurrence| occurrence.due_on <= month_end }
    @this_month = this_month.sort_by(&:due_on)
    @overdue = @overdue.sort_by(&:due_on)
    @dormant = @dormant.sort_by(&:due_on)

    # Beyond this month, one row per series is plenty -- a weekly bill's next
    # six occurrences are not six separate things to think about yet.
    @later = later.group_by(&:recurring_transaction_id)
                  .values
                  .map { |group| group.min_by(&:due_on) }
                  .sort_by(&:due_on)

    @paid_this_month = closed.select { |occurrence| occurrence.paid? && occurrence.due_on >= today.beginning_of_month }
                             .sort_by(&:due_on)

    compute_kpis(today, month_end)

    @suggested_allocations = suggested_allocations
  end

  # One bill's complete story: current state, payment history, what is
  # coming, and what it has cost.
  def show
    @series = Current.family.recurring_transactions
                     .accessible_by(Current.user)
                     .includes(:merchant)
                     .find(params[:id])

    @current_occurrence = @series.current_occurrence
    @history = @series.recurring_occurrences.closed.order(due_on: :desc).limit(12).includes(:allocations)
    @upcoming = @series.schedule.occurrences_between(Date.current + 1, Date.current + 400).first(3)

    paid_amounts = @series.recurring_occurrences.paid.pluck(:expected_amount).compact
    @analytics = if paid_amounts.any?
      {
        average: Money.new(paid_amounts.sum / paid_amounts.size, @series.currency),
        lowest: Money.new(paid_amounts.min, @series.currency),
        highest: Money.new(paid_amounts.max, @series.currency),
        annualized: @series.monthly_equivalent_amount * 12,
        ytd: Money.new(ytd_paid_total, @series.currency)
      }
    end

    render layout: dialog_layout
  end

  private
    # The management table: every series of every type and status, filterable
    # and sortable. This is the power-user surface; the overview stays a
    # worklist.
    def load_all_series
      scope = Current.family.recurring_transactions
                     .accessible_by(Current.user)
                     .includes(:merchant)

      if (search = params.dig(:q, :search)).present?
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(search)}%"
        scope = scope.left_joins(:merchant)
                     .where("recurring_transactions.name ILIKE :p OR merchants.name ILIKE :p", p: pattern)
      end

      if (status = params.dig(:q, :status)).presence_in(RecurringTransaction.statuses.keys)
        scope = scope.where(status: status)
      end

      if (bill_type = params.dig(:q, :bill_type)).presence_in(RecurringTransaction.bill_types.keys)
        scope = scope.where(bill_type: bill_type)
      end

      @all_series = case params.dig(:q, :sort)
      when "name" then scope.order(:name, :amount)
      when "amount" then scope.order(amount: :desc)
      else scope.order(status: :asc, next_expected_date: :asc)
      end
    end

    def dialog_layout
      turbo_frame_request? ? false : "settings"
    end

    # Months are materialized on demand up to 13 months out (idempotent
    # upserts, so navigation is free to re-visit); navigation caps there,
    # which keeps every rendered chip a real, clickable occurrence.
    CALENDAR_FORWARD_LIMIT_MONTHS = 13

    def load_calendar
      today = Date.current
      @month = begin
        Date.strptime(params[:month].to_s, "%Y-%m").beginning_of_month
      rescue ArgumentError
        today.beginning_of_month
      end

      limit = (today + CALENDAR_FORWARD_LIMIT_MONTHS.months).beginning_of_month
      @month = limit if @month > limit
      @at_forward_limit = @month >= limit

      @grid_start = @month.beginning_of_week(:sunday)
      @grid_end = @month.end_of_month.end_of_week(:sunday)

      materialize_for_calendar(@grid_end) if @grid_end > today + 89

      occurrences = Current.family.recurring_occurrences
                           .where(recurring_transaction_id: payable_series_ids)
                           .due_between(@grid_start, @grid_end)
                           .includes(recurring_transaction: :merchant)
                           .to_a
      preload_allocation_sums(occurrences)

      @by_day = occurrences.group_by(&:due_on)
      month_occurrences = occurrences.select { |occurrence| occurrence.due_on.between?(@month, @month.end_of_month) }
      @month_expected, @month_unconvertible = total_of(month_occurrences) { |occurrence| occurrence.resolved_expected_amount_money }
      @month_paid, _ = total_of(month_occurrences) { |occurrence| occurrence.confirmed_allocated_money }
    end

    def materialize_for_calendar(through)
      Current.family.recurring_transactions
             .active
             .where(id: payable_series_ids)
             .find_each do |series|
        RecurringTransaction::OccurrenceGenerator.new(series).generate!(through: through)
      end
    end

    def ytd_paid_total
      RecurringAllocation.confirmed
                         .joins(:recurring_occurrence)
                         .where(recurring_occurrences: { recurring_transaction_id: @series.id })
                         .where("recurring_allocations.paid_on >= ?", Date.current.beginning_of_year)
                         .sum(:allocated_amount)
    end

    # Open occurrences through the horizon plus everything closed this
    # month, for every payable series (bills, subscriptions, and debt
    # payments alike). Inactive series ride along so their leftover open
    # occurrences can render as Dormant instead of haunting Past Due.
    def payable_series_ids
      debt_accounts = Account.where(accountable_type: %w[CreditCard Loan]).select(:id)

      Current.family.recurring_transactions
             .where(status: %w[active inactive])
             .where("amount > 0")
             .merge(
               RecurringTransaction.where(destination_account_id: nil)
                                   .or(RecurringTransaction.where(destination_account_id: debt_accounts))
             )
             .accessible_by(Current.user)
             .select(:id)
    end

    def payable_occurrences
      Current.family.recurring_occurrences
             .where(recurring_transaction_id: payable_series_ids)
             .where("due_on >= ? OR status = 'scheduled'", Date.current.beginning_of_month)
             .where("due_on <= ?", Date.current + 90)
             .includes(recurring_transaction: :merchant)
             .to_a
    end

    def preload_allocation_sums(occurrences)
      sums = RecurringAllocation.confirmed
                                .where(recurring_occurrence_id: occurrences.map(&:id))
                                .group(:recurring_occurrence_id)
                                .sum(:allocated_amount)

      occurrences.each do |occurrence|
        occurrence.cached_confirmed_allocated = sums.fetch(occurrence.id, 0)
      end
    end

    def compute_kpis(today, month_end)
      owed_now = @overdue + @this_month

      @remaining_this_month, @unconvertible_count = total_of(owed_now) { |occurrence| occurrence.remaining_amount_money }
      @paid_this_month_total, _ = total_of(@paid_this_month) { |occurrence| occurrence.confirmed_allocated_money }
      @due_next_seven, _ = total_of(owed_now.select { |occurrence| occurrence.effective_due_on <= today + 7 }) { |occurrence| occurrence.remaining_amount_money }
      @past_due_total, _ = total_of(@overdue) { |occurrence| occurrence.remaining_amount_money }
      @owed_count = owed_now.size
      @needs_action_count = owed_now.count { |occurrence| !occurrence.recurring_transaction.autopay? }
    end

    def suggested_allocations
      RecurringAllocation
        .suggested
        .joins(recurring_occurrence: :recurring_transaction)
        .where(recurring_occurrences: { family_id: Current.family.id })
        .merge(RecurringTransaction.accessible_by(Current.user))
        .includes(:entry, recurring_occurrence: { recurring_transaction: :merchant })
        .order(:created_at)
    end

    # Converted into the family currency because the headline answers "how
    # much do I owe", which is one number. A pair with no rate is left out
    # and counted rather than silently understating the total. Returns
    # [total, unconvertible_count] so each caller keeps its own count.
    def total_of(occurrences, &value_of)
      return [ nil, 0 ] if occurrences.empty?

      target = Current.family.currency
      unconvertible = 0

      total = occurrences.reduce(Money.new(0, target)) do |sum, occurrence|
        begin
          sum + value_of.call(occurrence).exchange_to(target)
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
