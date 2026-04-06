class InterestPayoutJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    prev_month = Date.current.prev_month
    year = prev_month.year
    month = prev_month.month

    Depository.where(interest_enabled: true).find_each do |depository|
      pay_interest(depository, year, month)
    rescue => e
      Rails.logger.error("Failed to pay interest for depository #{depository.id}: #{e.message}")
    end
  end

  private

  def pay_interest(depository, year, month)
    unpaid_accruals = depository.interest_accruals.unpaid.for_month(year, month)
    total = unpaid_accruals.sum(:amount)
    return if total <= 0

    account = depository.account
    payout_date = Date.current

    # Idempotency: check if we already created this payout
    return if account.entries.where(name: interest_payment_name(year, month), date: payout_date).exists?

    family = account.family
    category = family.categories.find_or_create_by!(name: "Interest") do |c|
      c.color = "#22c55e"
      c.lucide_icon = "percent"
    end

    tag = family.tags.find_or_create_by!(name: "auto-generated")

    ActiveRecord::Base.transaction do
      entry = account.entries.create!(
        name: interest_payment_name(year, month),
        date: payout_date,
        amount: -total,
        currency: account.currency,
        entryable: Transaction.new(category: category)
      )

      entry.transaction.tags << tag

      unpaid_accruals.update_all(paid_out: true)
    end

    account.sync_later
  end

  def interest_payment_name(year, month)
    month_name = Date::MONTHNAMES[month]
    "Interest Payment — #{month_name} #{year}"
  end
end
