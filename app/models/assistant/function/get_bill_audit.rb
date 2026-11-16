class Assistant::Function::GetBillAudit < Assistant::Function
  include Assistant::Function::BillsSupport

  SECTION_LIMIT = 20
  NOTICE_WINDOW_DAYS = 30

  class << self
    def name
      "get_bill_audit"
    end

    def description
      <<~INSTRUCTIONS
        Audit the user's bills and subscriptions and return the facts a review needs:
        possible duplicate bills, recent price changes, trials about to convert,
        upcoming renewals, bills overdue by at least one whole billing cycle, paused
        bills still carrying unpaid occurrences, detections awaiting the user's
        confirmation, and recurring charge patterns the user has not declared yet.

        Every section is computed deterministically from the user's data; narrate and
        prioritize the findings rather than recomputing them. Duplicate detection is
        deliberately strict (same name, amount and due day), so two subscription tiers
        to one merchant are never flagged as duplicates. Propose specific fixes and ask
        before changing anything.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        lookback_months: {
          type: "integer", minimum: 1, maximum: 24,
          description: "How far back to report price changes (default 12 months)."
        }
      }
    )
  end

  def call(params = {})
    return recurring_disabled_result if recurring_disabled?

    # Same contract as get_bills' due_within_days: a present value outside the
    # range is rejected, not silently adjusted to answer a different question.
    if params["lookback_months"].present?
      lookback = Integer(params["lookback_months"].to_s, exception: false)
      unless lookback&.between?(1, 24)
        return {
          error: "lookback_months must be a whole number between 1 and 24",
          hint: "Retry once with a value in that range, or omit it for 12."
        }
      end
    else
      lookback = 12
    end
    active = accessible_series.active
                              .includes(:merchant, :account, :recurrence_rules)
                              .to_a

    {
      as_of_date: Date.current.iso8601,
      possible_duplicates: section(possible_duplicates(active)),
      price_changes: section(price_changes(lookback)),
      upcoming_trials: section(upcoming(active, :trial_ends_on)),
      upcoming_renewals: section(upcoming(active, :renews_on)),
      long_overdue: section(long_overdue(active)),
      dormant: section(dormant),
      awaiting_confirmation: section(awaiting_confirmation),
      undeclared_candidates: section(undeclared_candidates)
    }
  end

  private
    def section(items)
      { items: items.first(SECTION_LIMIT), truncated: items.size > SECTION_LIMIT, count: items.size }
    end

    def possible_duplicates(active)
      active.group_by(&:duplicate_key)
            .values
            .select { |group| group.size > 1 }
            .map do |group|
        {
          name: group.first.display_name,
          amount: group.first.amount_money.abs.format,
          bills: group.map { |series| { id: series.id, account: series.account&.name } }
        }
      end
    end

    def price_changes(lookback_months)
      RecurringPriceChange.joins(:recurring_transaction)
                          .merge(accessible_series)
                          .where("effective_on >= ?", lookback_months.months.ago.to_date)
                          .includes(:recurring_transaction)
                          .order(effective_on: :desc)
                          .map do |change|
        {
          bill: change.recurring_transaction.display_name,
          bill_id: change.recurring_transaction_id,
          effective_on: change.effective_on.iso8601,
          previous_amount: Money.new(change.previous_amount, change.currency).abs.format,
          new_amount: Money.new(change.new_amount, change.currency).abs.format,
          percent_change: percent_change(change.previous_amount, change.new_amount)
        }.compact
      end
    end

    def upcoming(active, date_column)
      window = Date.current..(Date.current + NOTICE_WINDOW_DAYS)

      active.select { |series| window.cover?(series.public_send(date_column)) }
            .sort_by { |series| series.public_send(date_column) }
            .map do |series|
        {
          bill_id: series.id,
          name: series.display_name,
          date: series.public_send(date_column).iso8601,
          amount: series.amount_money.abs.format
        }
      end
    end

    # A whole billing cycle late in the series' own cadence: meaningful for
    # weekly and annual bills alike, where a flat day threshold is not.
    def long_overdue(active)
      active.select { |series| spend_series?(series) && series.cycles_overdue >= 1 }
            .sort_by { |series| -series.cycles_overdue }
            .map do |series|
        {
          bill_id: series.id,
          name: series.display_name,
          cycles_overdue: series.cycles_overdue,
          next_due_date: series.next_due_date&.iso8601,
          amount: series.amount_money.abs.format
        }
      end
    end

    # Paused bills still carrying open occurrences: set aside but not settled.
    def dormant
      accessible_series.where(status: STATUS_VOCABULARY.fetch("paused"))
                       .joins(:recurring_occurrences)
                       .merge(RecurringOccurrence.open_status)
                       .distinct
                       .map do |series|
        { bill_id: series.id, name: series.display_name, status: display_status(series) }
      end
    end

    def awaiting_confirmation
      accessible_series.suggested.order(next_expected_date: :asc).map do |series|
        { bill_id: series.id, name: series.display_name, amount: series.amount_money.abs.format }
      end
    end

    # The same clustering the add-bill dialog offers: recurring outflow shapes
    # detection spotted that no series covers yet. Patterns are family-wide,
    # so they are filtered to the accounts this user can actually reach.
    def undeclared_candidates
      accessible_ids = Account.accessible_by(user).pluck(:id)

      RecurringTransaction::Identifier.new(family)
                                      .candidate_patterns(sign: :outflow)
                                      .select { |pattern| accessible_ids.include?(pattern[:account_id]) }
                                      .sort_by { |pattern| pattern[:last_occurrence_date] }
                                      .reverse
                                      .map do |pattern|
        {
          name: pattern[:name],
          average_amount: Money.new(pattern[:expected_amount_avg].abs, pattern[:currency]).format,
          occurrence_count: pattern[:occurrence_count],
          last_seen: pattern[:last_occurrence_date].iso8601
        }
      end
    end
end
