class Insight::Generators::SubscriptionAuditGenerator < Insight::Generator
  OVERDUE_DAYS = 45

  def generate
    cutoff = Date.current - OVERDUE_DAYS.days

    overdue = family.recurring_transactions
      .active
      .where("next_expected_date < ?", cutoff)
      .where.not(next_expected_date: nil)

    overdue.find_each.filter_map do |rt|
      name = rt.merchant&.name.presence || rt.name.presence
      next if name.blank?

      days_overdue = (Date.current - rt.next_expected_date).to_i
      amount = rt.amount.abs

      metadata = {
        "recurring_transaction_id" => rt.id,
        "name" => name,
        "days_overdue" => days_overdue,
        "expected_amount" => amount.round(2),
        "last_occurrence_date" => rt.last_occurrence_date&.iso8601
      }

      fallback = "We haven't seen your recurring #{name} charge (about #{format_money(amount)}) in #{days_overdue} days. " \
                 "It may have been cancelled or changed."

      body = generate_body(
        facts: {
          signal: "subscription_audit",
          name: name,
          expected_amount: format_money(amount),
          days_overdue: days_overdue
        },
        fallback: fallback
      )

      GeneratedInsight.new(
        insight_type: "subscription_audit",
        priority: "medium",
        title: "#{name} may have stopped",
        body: body,
        metadata: metadata,
        currency: currency,
        period_start: rt.last_occurrence_date,
        period_end: Date.current,
        dedup_key: "subscription_audit:#{rt.id}"
      )
    end
  end
end
