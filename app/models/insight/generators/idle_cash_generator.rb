class Insight::Generators::IdleCashGenerator < Insight::Generator
  MIN_BALANCE = 5_000
  IDLE_DAYS = 60

  def generate
    cutoff = Date.current - IDLE_DAYS.days

    family.accounts.visible.where(accountable_type: "Depository").find_each.filter_map do |account|
      balance = convert_to_family_currency(account.balance, account.currency)
      next if balance < MIN_BALANCE

      last_entry_date = account.entries.where(entryable_type: "Transaction").maximum(:date)
      next if last_entry_date.present? && last_entry_date > cutoff

      days_idle = last_entry_date.present? ? (Date.current - last_entry_date).to_i : nil

      metadata = {
        "account_id" => account.id,
        "account_name" => account.name,
        "balance" => balance.round(2),
        "days_idle" => days_idle,
        "last_activity_date" => last_entry_date&.iso8601
      }

      idle_phrase = days_idle ? "#{days_idle} days" : "over #{IDLE_DAYS} days"
      fallback = "#{account.name} holds #{format_money(balance)} and hasn't had any activity in #{idle_phrase}. " \
                 "Idle cash may be worth putting to work."

      body = generate_body(
        facts: {
          signal: "idle_cash",
          account_name: account.name,
          balance: format_money(balance),
          days_idle: days_idle || IDLE_DAYS
        },
        fallback: fallback
      )

      GeneratedInsight.new(
        insight_type: "idle_cash",
        priority: "low",
        title: "Idle cash in #{account.name}",
        body: body,
        metadata: metadata,
        currency: currency,
        period_start: last_entry_date,
        period_end: Date.current,
        dedup_key: "idle_cash:#{account.id}:#{Date.current.strftime('%Y-%m')}"
      )
    end
  end

  private
    def convert_to_family_currency(amount, from_currency)
      return amount.to_f if from_currency == family.currency

      Money.new(amount, from_currency).exchange_to(family.currency).amount.to_f
    rescue Money::ConversionError
      amount.to_f
    end
end
