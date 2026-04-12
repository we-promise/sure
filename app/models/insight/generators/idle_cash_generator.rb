# Flags depository accounts with a material balance that has seen no transaction
# activity for an extended period — suggesting idle cash that could be earning more.
class Insight::Generators::IdleCashGenerator < Insight::Generator
  IDLE_THRESHOLD_DAYS   = 60
  IDLE_AMOUNT_THRESHOLD = 5_000

  def generate
    depository_accounts = family.accounts.visible.assets.where(accountable_type: "Depository")

    active_account_ids = Entry
      .where(account_id: depository_accounts.select(:id))
      .where("date >= ?", IDLE_THRESHOLD_DAYS.days.ago.to_date)
      .where(entryable_type: "Transaction")
      .distinct
      .pluck(:account_id)

    depository_accounts.where.not(id: active_account_ids).filter_map do |account|
      balance = account.balance.to_f
      next unless balance >= IDLE_AMOUNT_THRESHOLD

      metadata = {
        "account_id"   => account.id,
        "account_name" => account.name,
        "idle_amount"  => balance.round(2),
        "idle_days"    => IDLE_THRESHOLD_DAYS
      }

      body = generate_body(
        "#{currency_symbol}#{balance.round(2)} has been sitting in #{account.name} " \
        "for over #{IDLE_THRESHOLD_DAYS} days without any transactions. " \
        "Consider whether this cash could be working in a higher-yield account."
      )

      GeneratedInsight.new(
        insight_type: "idle_cash",
        priority:     "low",
        title:        I18n.t("insights.idle_cash.title", account: account.name),
        body:         body,
        metadata:     metadata,
        currency:     family.currency,
        period_start: IDLE_THRESHOLD_DAYS.days.ago.to_date,
        period_end:   Date.current,
        dedup_key:    "idle_cash:#{account.id}:#{Date.current.strftime("%Y-%m")}"
      )
    end
  end
end
