# Identifies recurring transactions that are overdue — meaning they haven't appeared
# in the family's entries for longer than expected. This signals a subscription may
# have been cancelled, changed, or is otherwise worth reviewing.
class Insight::Generators::SubscriptionAuditGenerator < Insight::Generator
  OVERDUE_DAYS = 45  # days past last_occurrence_date before we flag it

  def generate
    stale = family.recurring_transactions
      .active
      .where("last_occurrence_date < ?", OVERDUE_DAYS.days.ago.to_date)
      .where("next_expected_date < ?", Date.current)
      .includes(:merchant)
      .order(last_occurrence_date: :asc)
      .limit(5)

    return [] if stale.empty?

    stale.map do |rt|
      display_name = rt.merchant&.name || rt.name
      monthly_cost = (rt.expected_amount_avg || rt.amount).to_f.abs

      metadata = {
        "recurring_transaction_id" => rt.id,
        "merchant_name"            => display_name,
        "monthly_cost"             => monthly_cost.round(2),
        "last_seen_date"           => rt.last_occurrence_date.iso8601,
        "days_overdue"             => (Date.current - rt.last_occurrence_date).to_i
      }

      body = generate_body(
        "#{display_name} (#{currency_symbol}#{monthly_cost.round(2)}/month) " \
        "hasn't appeared in your transactions since #{rt.last_occurrence_date.strftime("%B %-d")}. " \
        "It may have been cancelled or changed."
      )

      GeneratedInsight.new(
        insight_type: "subscription_audit",
        priority:     "medium",
        title:        I18n.t("insights.subscription_audit.title", name: display_name),
        body:         body,
        metadata:     metadata,
        currency:     family.currency,
        period_start: rt.last_occurrence_date,
        period_end:   Date.current,
        dedup_key:    "subscription_audit:#{rt.id}:#{Date.current.strftime("%Y-%m")}"
      )
    end
  end
end
