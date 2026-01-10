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

  after_save :update_account_opening_balance

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
      self.installment_cost_cents = amount.round
    else
      self.installment_cost_cents = value.to_f.round
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

  def time_elapsed_breakdown
    return nil unless first_payment_date

    now = Date.current
    return nil if now < first_payment_date

    months_elapsed = (now.year * 12 + now.month) - (first_payment_date.year * 12 + first_payment_date.month)

    {
      weeks: ((now - first_payment_date) / 7.0).floor,
      months: months_elapsed,
      quarters: (months_elapsed / 3.0).floor,
      years: (months_elapsed / 12.0).floor
    }
  end

  def payments_made_count
    transactions.joins(:entry).count
  end

  def last_payment_account
    transactions.joins(:entry)
                .order("entries.date DESC, entries.created_at DESC")
                .limit(1)
                .pick("entries.account_id")
                .then { |account_id| account_id && Account.find_by(id: account_id) }
  end

  def remaining_installments
    return nil unless total_installments

    remaining = total_installments - payments_made_count
    remaining.positive? ? remaining : 0
  end

  def next_due_date
    return nil unless list_attributes_present?
    return nil if remaining_installments.to_i.zero?

    due_date_for_index(payments_made_count)
  end

  def overdue?
    return false unless next_due_date

    next_due_date < Date.current
  end

  def due_soon?(window_days: 3)
    return false unless next_due_date

    next_due_date >= Date.current && next_due_date <= Date.current + window_days.days
  end

  def current_month_payment_total
    return Money.new(0, currency) unless list_attributes_present?

    month_start = Date.current.beginning_of_month
    month_end = Date.current.end_of_month

    due_dates = scheduled_due_dates_between(month_start, month_end)
    return Money.new(0, currency) if due_dates.empty?

    total_cents = due_dates.sum do |due_date|
      existing = transactions.joins(:entry).where(entries: { date: due_date })
      if existing.exists?
        existing.sum("ABS(entries.amount)")
      else
        installment_cost.amount
      end
    end

    Money.new(total_cents, currency)
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

    def due_date_for_index(index)
      case payment_period
      when "weekly"
        first_payment_date + index.weeks
      when "monthly"
        first_payment_date + index.months
      when "quarterly"
        first_payment_date + index.quarters
      when "yearly"
        first_payment_date + index.years
      else
        first_payment_date
      end
    end

    def scheduled_due_dates_between(start_date, end_date)
      return [] unless list_attributes_present?

      dates = []
      total_installments.times do |i|
        due_date = due_date_for_index(i)
        next if due_date < start_date
        break if due_date > end_date

        dates << due_date
      end

      dates
    end

    def update_account_opening_balance
      return unless account

      # Update the opening balance to match the total cost of the installment
      # This ensures that Balance (Remaining Cost) = Total Cost (Opening Balance) - Paid (Entries)
      Account::OpeningBalanceManager.new(account).set_opening_balance(balance: total_cost.amount)
      account.sync_later
    end
end
