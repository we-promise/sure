# Points out sizable cash balances that have sat untouched for a while. Low
# priority by design — it's a nudge, not a warning. The dedup key rotates
# monthly so a dismissed nudge stays gone for the rest of the month.
class Insight::Generators::IdleCashGenerator < Insight::Generator
  produces "idle_cash"

  # Known limitation: family-currency units, tuned for dollar/euro-scale
  # currencies (¥5,000 ≈ $33 would make this fire on trivial balances).
  MIN_BALANCE = 5_000
  IDLE_DAYS = 60
  MAX_INSIGHTS = 2

  def generate
    idle_accounts.first(MAX_INSIGHTS).map do |account|
      build_insight(
        insight_type: "idle_cash",
        priority: "low",
        title: I18n.t("insights.titles.idle_cash", account: account.name),
        template_key: "idle_cash",
        facts: {
          account: account.name,
          balance: format_money(account.balance),
          idle_days: IDLE_DAYS
        },
        metadata: {
          account_id: account.id,
          balance: round(account.balance, 0)
        },
        dedup_key: "idle_cash:#{account.id}:#{month_token}"
      )
    end
  end

  private
    # Ordered so the pick is stable between runs — an unordered relation could
    # nudge a different pair of accounts each night, churning the feed.
    def idle_accounts
      family.accounts.visible
        .where(accountable_type: "Depository", currency: family.currency)
        .where("balance >= ?", MIN_BALANCE)
        .where.not(id: Entry.where("date >= ?", IDLE_DAYS.days.ago.to_date).select(:account_id))
        .order(balance: :desc)
    end
end
