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
      amount = Money.new(recurring.amount, recurring.currency).format
      days_overdue = (Date.current - recurring.next_expected_date).to_i

      build_insight(
        insight_type: "subscription_audit",
        priority: "medium",
        title: I18n.t("insights.titles.subscription_audit", name: name),
        template_key: "subscription_audit",
        facts: {
          name: name,
          amount: amount,
          days_overdue: days_overdue,
          expected_on: I18n.l(recurring.next_expected_date)
        },
        # days_overdue is deliberately left out: it changes every night, and
        # metadata drift would resurrect insights the user already dismissed.
        metadata: {
          recurring_transaction_id: recurring.id,
          amount: round(recurring.amount, 2),
          expected_on: recurring.next_expected_date.iso8601
        },
        dedup_key: "subscription_audit:#{recurring.id}"
      )
    end
  end

  private
    def overdue_recurring
      family.recurring_transactions
        .active
        .where(destination_account_id: nil)
        .where("amount > 0")
        .where("next_expected_date < ?", OVERDUE_DAYS.days.ago.to_date)
        .order(:next_expected_date)
        .limit(MAX_INSIGHTS)
    end
end
