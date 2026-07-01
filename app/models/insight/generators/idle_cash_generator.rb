# Points out sizable cash balances that have sat untouched for a while. Low
# priority by design — it's a nudge, not a warning. The dedup key rotates
# monthly so a dismissed nudge stays gone for the rest of the month.
class Insight::Generators::IdleCashGenerator < Insight::Generator
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
    def idle_accounts
      family.accounts.visible
        .where(accountable_type: "Depository", currency: family.currency)
        .where("balance >= ?", MIN_BALANCE)
        .reject { |account| account.entries.where("date >= ?", IDLE_DAYS.days.ago.to_date).exists? }
    end
end
