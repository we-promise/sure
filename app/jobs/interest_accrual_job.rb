class InterestAccrualJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    Depository.where(interest_enabled: true).find_each do |depository|
      accrue_interest(depository)
    rescue => e
      Rails.logger.error("Failed to accrue interest for depository #{depository.id}: #{e.message}")
    end
  end

  private

  def accrue_interest(depository)
    return unless depository.interest_eligible?

    date = Date.current
    return if InterestAccrual.exists?(depository: depository, date: date)

    account = depository.account
    balance = account.balance
    return if balance.nil? || balance <= 0

    daily_rate = depository.daily_interest_rate(date)
    accrued = (balance * daily_rate).round(4)

    InterestAccrual.create!(
      depository: depository,
      date: date,
      balance_used: balance,
      daily_rate: daily_rate,
      amount: accrued
    )
  end
end
