class Assistant::Function::GetRecurringTransactions < Assistant::Function
  MAX_RESULTS = 200

  class << self
    def name
      "get_recurring_transactions"
    end

    def description
      <<~INSTRUCTIONS
        Lists detected and manual recurring transactions (subscriptions, salaries,
        recurring bills and transfers) with expected amounts and next expected dates.

        Great for questions like: What subscriptions am I paying for? What bills are
        coming up this month? How much recurring spend do I have?

        `status` defaults to "active". Pass `upcoming_within_days` to only see items
        expected between today and that many days from now (overdue items appear
        when no window is given). totals_by_currency sums active items excluding
        transfers, which move money between the user's own accounts.
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
        status: {
          type: "string",
          enum: [ "active", "inactive", "all" ],
          description: "Filter by status (defaults to active)"
        },
        upcoming_within_days: {
          type: "integer",
          minimum: 1,
          maximum: 365,
          description: "Only include items whose next expected date falls within this many days"
        }
      }
    )
  end

  def call(params = {})
    scope = family.recurring_transactions
      .accessible_by(user)
      .includes(:merchant, :account, :destination_account)

    status = params["status"].presence_in([ "active", "inactive", "all" ]) || "active"
    scope = scope.where(status: status) unless status == "all"

    if params["upcoming_within_days"].present?
      days = params["upcoming_within_days"].to_i.clamp(1, 365)
      # A forward-looking window: overdue items (past next_expected_date)
      # appear in unwindowed calls, not inside "the next N days".
      scope = scope.where(next_expected_date: Date.current..days.days.from_now.to_date)
    end

    total_count = scope.count
    rows = scope.order(status: :asc, next_expected_date: :asc).limit(MAX_RESULTS).to_a

    {
      as_of_date: Date.current,
      total_results: total_count,
      truncated: total_count > MAX_RESULTS,
      recurring_transactions: rows.map { |rt| serialize(rt) },
      totals_by_currency: totals_by_currency(scope)
    }
  end

  private
    def serialize(recurring)
      {
        id: recurring.id,
        name: recurring.name || recurring.merchant&.name,
        amount: recurring.amount_money.format,
        expected_amount_range: expected_amount_range(recurring),
        currency: recurring.currency,
        status: recurring.status,
        expected_day_of_month: recurring.expected_day_of_month,
        next_expected_date: recurring.next_expected_date,
        last_occurrence_date: recurring.last_occurrence_date,
        occurrence_count: recurring.occurrence_count,
        is_manual: recurring.manual?,
        is_transfer: recurring.transfer?,
        account: account_ref(recurring.account),
        destination_account: account_ref(recurring.destination_account)
      }.compact
    end

    def account_ref(account)
      return nil if account.nil?

      { id: account.id, name: account.name }
    end

    def expected_amount_range(recurring)
      [ recurring.expected_amount_min_money&.format, recurring.expected_amount_max_money&.format ].compact.presence
    end

    # Transfers are excluded: money moving between the user's own accounts is
    # not recurring spend, however regular it is. Summed over the full
    # filtered scope (not the displayed rows) so a truncated list never
    # reports a partial sum as the total.
    def totals_by_currency(scope)
      scope.where(status: "active", destination_account_id: nil)
        .group(:currency)
        .sum(:amount)
        .each_with_object({}) { |(currency, sum), totals| totals[currency] = Money.new(sum, currency).format }
    end
end
