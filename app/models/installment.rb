class Installment < ApplicationRecord
  include Accountable

  has_many :recurring_transactions, dependent: :destroy

  SUBTYPES = {}.freeze

  class << self
    def color
      "#F59E0B"
    end

    def icon
      "calendar-check"
    end

    def classification
      "liability"
    end
  end

  # Virtual attributes (used during creation, not persisted)
  attr_accessor :source_account_id, :payment_day

  enum :payment_period, {
    weekly: "weekly",
    bi_weekly: "bi_weekly",
    monthly: "monthly",
    quarterly: "quarterly",
    yearly: "yearly"
  }, validate: true

  validates :installment_cost, presence: true, numericality: { greater_than: 0 }
  validates :total_term, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :current_term, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :payment_period, presence: true
  validates :first_payment_date, presence: true
  validate :current_term_not_greater_than_total_term

  def currency
    account&.currency
  end

  # Calculate most_recent_payment_date from first_payment_date + current_term
  def calculated_most_recent_payment_date
    return nil if current_term.zero?
    calculate_payment_date_for_term(current_term)
  end

  # Calculate the payment date for a specific term number
  def calculate_payment_date_for_term(term_number)
    return first_payment_date if term_number <= 1

    date = first_payment_date
    (term_number - 1).times { date = advance_date(date) }
    date
  end

  # Calculate the original loan balance (total to be paid)
  def calculate_original_balance
    installment_cost * total_term
  end

  # Calculate the current balance based on scheduled payments
  def calculate_current_balance
    return calculate_original_balance if current_term.zero?

    payments_remaining_count = [ total_term - payments_scheduled_to_date, 0 ].max
    payments_remaining_count * installment_cost
  end

  def remaining_principal_money
    Money.new(calculate_current_balance, currency)
  end

  # Generate the full payment schedule from first to last payment
  def generate_payment_schedule
    schedule = []
    date = first_payment_date

    total_term.times do |i|
      schedule << {
        payment_number: i + 1,
        date: date,
        amount: installment_cost
      }
      date = advance_date(date)
    end

    schedule
  end

  # Count of payments scheduled from first_payment_date to today
  def payments_scheduled_to_date
    return 0 if Date.current < first_payment_date

    schedule = generate_payment_schedule
    schedule.count { |payment| payment[:date] <= Date.current }
  end

  # Check if installment is complete based on actual transaction count
  def completed?
    payments_completed >= total_term
  end

  # Count of actual transactions linked to this installment
  def payments_completed
    account.transactions.where("extra->>'installment_id' = ?", id.to_s).count
  end

  # Get the date of the next scheduled payment
  def next_payment_date
    schedule = generate_payment_schedule
    next_payment = schedule.find { |payment| payment[:date] > Date.current }
    next_payment&.dig(:date)
  end

  # Number of payments remaining in the schedule
  def payments_remaining
    [ total_term - payments_completed, 0 ].max
  end

  private

    def advance_date(date)
      case payment_period
      when "weekly"
        date + 1.week
      when "bi_weekly"
        date + 2.weeks
      when "monthly"
        date + 1.month
      when "quarterly"
        date + 3.months
      when "yearly"
        date + 1.year
      else
        raise ArgumentError, "Unknown payment period: #{payment_period}"
      end
    end

    def current_term_not_greater_than_total_term
      return if current_term.nil? || total_term.nil?

      if current_term > total_term
        errors.add(:current_term, "cannot be greater than total term")
      end
    end
end
