class Installment < ApplicationRecord
  belongs_to :account

  after_create :ensure_account_subtype

  delegate :currency, to: :account

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
  # Note: most_recent_payment_date is now calculated, not required
  validate :current_term_not_greater_than_total_term
  validate :installment_cost_seems_reasonable

  # Calculate most_recent_payment_date from first_payment_date + current_term
  # This replaces the stored value - Payment Date serves as both first and recurring date
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

    def ensure_account_subtype
      return if account.subtype == "installment"

      account.update!(subtype: "installment")
    end

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

    def installment_cost_seems_reasonable
      return if installment_cost.nil? || total_term.nil?

      # Warn if installment seems too large relative to number of payments
      # For example, a $10,000 payment with only 2 total payments might be unusual
      # Check if payment is more than $10,000 and term is less than 3
      if installment_cost > 10_000 && total_term < 3
        errors.add(:installment_cost, "seems unusually high relative to total loan amount")
      end
    end
end
