class Installment < ApplicationRecord
  include Accountable, Monetizable

  # Installments don't have subtypes, but Account delegates this method
  def subtype
    nil
  end

  belongs_to :family
  has_many :transactions, dependent: :nullify

  validates :name, :total_installments, :payment_period, :first_payment_date, :installment_cost_cents, :currency, presence: true
  validates :total_installments, numericality: { greater_than: 0, only_integer: true }
  validates :installment_cost_cents, numericality: { greater_than: 0, only_integer: true }

  enum :payment_period, {
    weekly: "weekly",
    monthly: "monthly",
    quarterly: "quarterly",
    yearly: "yearly"
  }

  monetize :installment_cost_cents

  def installment_cost
    installment_cost_cents_money
  end

  def installment_cost=(value)
    if value.is_a?(String)
      # Remove non-numeric characters except dot and minus, then convert to float
      amount = value.gsub(/[^0-9.-]/, "").to_f
      self.installment_cost_cents = (amount * 100).round
    else
      self.installment_cost_cents = (value.to_f * 100).round
    end
  end

  def total_cost
    return Money.new(0, currency) unless list_attributes_present?
    installment_cost * total_installments
  end

  def remaining_cost
    total_cost - total_spent_to_date
  end

  def total_spent_to_date
    Money.new(transactions.joins(:entry).sum("ABS(entries.amount)"), currency)
  end

  def payout_progress
    return 0.0 if total_cost.amount.zero?
    (total_spent_to_date.amount.to_f / total_cost.amount.to_f) * 100
  end

  def last_payment_date
    return nil unless list_attributes_present?

    periods = total_installments - 1
    case payment_period
    when "weekly"
      first_payment_date + periods.weeks
    when "monthly"
      first_payment_date + periods.months
    when "quarterly"
      first_payment_date + periods.quarters
    when "yearly"
      first_payment_date + periods.years
    end
  end

  def time_elapsed
    return nil unless first_payment_date

    now = Date.current
    return 0 if now < first_payment_date

    case payment_period
    when "weekly"
      ((now - first_payment_date) / 7.0).floor
    when "monthly"
      (now.year * 12 + now.month) - (first_payment_date.year * 12 + first_payment_date.month)
    when "quarterly"
      ((now.year * 12 + now.month) - (first_payment_date.year * 12 + first_payment_date.month)) / 3
    when "yearly"
      now.year - first_payment_date.year
    else
      0
    end
  end

  class << self
    def icon
      "calendar-clock"
    end

    def color
      "#F59E0B"
    end

    def classification
      "liability"
    end
  end

  private

    def list_attributes_present?
      first_payment_date && total_installments && payment_period
    end
end
