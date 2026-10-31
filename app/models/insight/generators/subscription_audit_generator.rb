# Surfaces recurring expenses that are well past their expected date — the
# provider may have raised the price, the charge may have moved, or the user
# may be paying for something that quietly stopped (or should stop).
# Bills subsystem: the overdue threshold is now measured in the series' own
# cycles, so quarterly and annual bills are no longer judged by a flat 45 days.
class Insight::Generators::SubscriptionAuditGenerator < Insight::Generator
  produces "subscription_audit"

  OVERDUE_DAYS = 45
  MAX_INSIGHTS = 3

  def generate
    return [] if family.recurring_transactions_disabled?

    overdue_occurrences.map do |occurrence|
      recurring = occurrence.recurring_transaction
      name = recurring.merchant&.name.presence || recurring.name
      amount = Money.new(occurrence.resolved_expected_amount, occurrence.currency).format
      days_overdue = (Date.current - occurrence.due_on).to_i

      build_insight(
        insight_type: "subscription_audit",
        priority: "medium",
        title: I18n.t("insights.titles.subscription_audit", name: name),
        template_key: "subscription_audit",
        facts: {
          name: name,
          amount: amount,
          days_overdue: days_overdue,
          expected_on: I18n.l(occurrence.due_on)
        },
        # days_overdue is deliberately left out: it changes every night, and
        # metadata drift would resurrect insights the user already dismissed.
        metadata: {
          recurring_transaction_id: recurring.id,
          amount: round(occurrence.resolved_expected_amount, 2),
          expected_on: occurrence.due_on.iso8601
        },
        dedup_key: "subscription_audit:#{recurring.id}"
      )
    end
  end

  private
    # Cycle-aware staleness: an occurrence is worth nagging about once a
    # WHOLE additional cycle has come due while it sits unpaid -- days for a
    # weekly bill, a month for a monthly one, never a false alarm for
    # quarterly and annual bills between their perfectly normal occurrences.
    # (The old flat 45-day threshold was six missed cycles for a weekly bill
    # and noise for an annual one.)
    def overdue_occurrences
      candidates = family.recurring_occurrences
        .open_status
        .joins(:recurring_transaction)
        .where(recurring_transactions: { status: :active, destination_account_id: nil })
        .where("recurring_transactions.amount > 0")
        .where("due_on < ?", Date.current)
        .includes(recurring_transaction: [ :merchant, :recurrence_rules ])
        .to_a

      stale = candidates.select do |occurrence|
        cycle_days = 365.25 / occurrence.recurring_transaction.schedule.occurrences_per_year
        (Date.current - occurrence.due_on).to_i >= [ cycle_days.round, 1 ].max
      end

      stale.group_by(&:recurring_transaction_id)
           .values
           .map { |group| group.min_by(&:due_on) }
           .sort_by(&:due_on)
           .first(MAX_INSIGHTS)
    end
end
