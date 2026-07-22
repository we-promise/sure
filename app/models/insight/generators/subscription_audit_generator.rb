# Surfaces recurring expenses that are well past their expected date — the
# provider may have raised the price, the charge may have moved, or the user
# may be paying for something that quietly stopped (or should stop).
class Insight::Generators::SubscriptionAuditGenerator < Insight::Generator
  produces "subscription_audit"

  OVERDUE_DAYS = 45
  MAX_INSIGHTS = 3

  def generate
    overdue_recurring.map do |recurring|
      name = recurring.merchant&.name.presence || recurring.name
      days_overdue = (Date.current - recurring.next_expected_date).to_i

      build_insight(
        insight_type: "subscription_audit",
        priority: "medium",
        title: I18n.t("insights.titles.subscription_audit", name: name),
        template_key: "subscription_audit",
        facts: {
          name: name,
          # Recurring transaction currency may differ from the family's base
          # currency, so this fact carries its own instead of defaulting.
          amount: money_fact(recurring.amount, currency: recurring.currency),
          days_overdue: days_overdue,
          expected_on: recurring.next_expected_date.iso8601
        },
        # days_overdue is deliberately left out: it changes every night, and
        # metadata drift would resurrect insights the user already dismissed.
        metadata: {
          recurring_transaction_id: recurring.id,
          amount: round(recurring.amount, 2),
          currency: recurring.currency,
          expected_on: recurring.next_expected_date.iso8601
        },
        dedup_key: "subscription_audit:#{recurring.id}"
      )
    end
  end

  private
    def overdue_recurring
      family.recurring_transactions
        .includes(:merchant)
        .active
        .where(destination_account_id: nil)
        .where("amount > 0")
        .where("next_expected_date < ?", OVERDUE_DAYS.days.ago.to_date)
        .order(:next_expected_date)
        .limit(MAX_INSIGHTS)
    end
end
