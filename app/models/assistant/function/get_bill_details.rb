class Assistant::Function::GetBillDetails < Assistant::Function
  include Assistant::Function::BillsSupport

  HISTORY_LIMIT = 12
  PRICE_CHANGE_LOOKBACK_MONTHS = 24

  class << self
    def name
      "get_bill_details"
    end

    def description
      <<~INSTRUCTIONS
        Get one bill's complete story: full configuration, every open occurrence, the last
        #{HISTORY_LIMIT} settled occurrences with their payments, upcoming due dates, price-change
        history, and cost analytics.

        Analytics are computed from confirmed payments on settled occurrences only, never
        from estimates, and are null when nothing has been paid yet.

        bill_id must be the exact id returned by get_bills.
      INSTRUCTIONS
    end
  end

  def params_schema
    build_schema(
      required: [ "bill_id" ],
      properties: {
        bill_id: { type: "string", description: "The bill's id, exactly as returned by get_bills." }
      }
    )
  end

  def call(params = {})
    return recurring_disabled_result if recurring_disabled?

    series, error = find_series(params["bill_id"])
    return error if error

    open_occurrences = series.recurring_occurrences.open_status.order(:due_on).to_a
    history = series.recurring_occurrences.closed.order(due_on: :desc).limit(HISTORY_LIMIT).includes(allocations: :entry).to_a
    preload_allocation_sums(open_occurrences + history)

    {
      bill: serialize_series(series).merge(configuration(series)),
      analytics: analytics(series),
      open_occurrences: open_occurrences.map { |occurrence| serialize_occurrence(occurrence) },
      history: history.map { |occurrence| serialize_history_row(occurrence) },
      upcoming_due_dates: series.schedule.occurrences_between(Date.current + 1, Date.current + 400).first(3).map(&:iso8601),
      price_changes: price_changes(series)
    }
  end

  private
    def configuration(series)
      {
        amount_strategy: series.amount_strategy,
        weekend_adjust: series.weekend_adjust,
        end_mode: series.end_mode,
        end_on: series.end_on&.iso8601,
        end_after_count: series.end_after_count,
        anchor_date: series.anchor_date&.iso8601,
        notes: series.notes,
        notify_days_before: series.notify_days_before,
        overdue_grace_days: series.overdue_grace_days,
        trial_ends_on: series.trial_ends_on&.iso8601,
        renews_on: series.renews_on&.iso8601,
        cancelled_on: series.cancelled_on&.iso8601,
        schedule_pinned: series.schedule_pinned?,
        expected_amount_min: series.expected_amount_min_money&.abs&.format,
        expected_amount_max: series.expected_amount_max_money&.abs&.format,
        expected_amount_avg: series.expected_amount_avg_money&.abs&.format
      }.compact
    end

    # Same discipline as the bill page: what each settled cycle actually cost,
    # from confirmed allocations on paid occurrences. The frozen
    # expected_amount is an estimate; averaging estimates beside sums of real
    # payments would let the page disagree with itself.
    def analytics(series)
      paid_amounts = RecurringAllocation.confirmed
                                        .joins(:recurring_occurrence)
                                        .where(recurring_occurrences: {
                                                 recurring_transaction_id: series.id,
                                                 status: "paid"
                                               })
                                        .group(:recurring_occurrence_id)
                                        .sum(:allocated_amount)
                                        .values

      return nil if paid_amounts.empty?

      ytd = RecurringAllocation.confirmed
                               .joins(:recurring_occurrence)
                               .where(recurring_occurrences: { recurring_transaction_id: series.id })
                               .where("recurring_allocations.paid_on >= ?", Date.current.beginning_of_year)
                               .sum(:allocated_amount)

      {
        average_paid: Money.new(paid_amounts.sum / paid_amounts.size, series.currency).format,
        lowest_paid: Money.new(paid_amounts.min, series.currency).format,
        highest_paid: Money.new(paid_amounts.max, series.currency).format,
        annualized_cost: (series.monthly_equivalent_amount * 12).abs.format,
        paid_this_year: Money.new(ytd, series.currency).format
      }
    end

    def serialize_history_row(occurrence)
      serialize_occurrence(occurrence).merge(
        status: occurrence.status,
        payments: occurrence.allocations.map do |allocation|
          {
            amount: allocation.allocated_amount_money.format,
            paid_on: allocation.paid_on&.iso8601,
            source: allocation.source,
            state: allocation.state,
            transaction_name: allocation.entry&.name
          }.compact
        end
      )
    end

    def price_changes(series)
      series.recurring_price_changes
            .where("effective_on >= ?", PRICE_CHANGE_LOOKBACK_MONTHS.months.ago.to_date)
            .order(effective_on: :desc)
            .map do |change|
        {
          effective_on: change.effective_on.iso8601,
          previous_amount: Money.new(change.previous_amount, change.currency).abs.format,
          new_amount: Money.new(change.new_amount, change.currency).abs.format,
          percent_change: percent_change(change.previous_amount, change.new_amount),
          source: change.source
        }
      end
    end
end
