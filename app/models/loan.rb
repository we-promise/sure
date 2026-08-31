class Loan < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "home_equity" => { short: "Home Equity", long: "Home Equity Loan" },
    "line_of_credit" => { short: "Line of Credit", long: "Line of Credit" },
    "business" => { short: "Business Loan", long: "Business Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze

  has_many :amortizations, class_name: "LoanAmortization", dependent: :destroy

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true

  after_save :rebuild_amortization_schedule, if: :amortization_inputs_changed?

  # Get the monthly payment amount for this loan
  def monthly_payment
    amortization_schedule.monthly_payment
  end

  # Get the original loan balance as a Money object
  def original_balance
    Money.new(account.first_valuation_amount, account.currency)
  end

  # Get or create the amortization schedule calculator
  def amortization_schedule
    @amortization_schedule ||= AmortizationSchedule.new(self)
  end

  # Check if this loan can be amortized
  def amortizable?
    amortization_schedule.amortizable?
  end

  # Add or update a variable interest rate change on a specific date
  def add_variable_rate_change(date, rate)
    self.variable_rate_schedule ||= {}
    self.variable_rate_schedule[date.to_s] = rate
    self.next_rate_change_date = find_next_rate_change_date
    save
  end

  # Get all variable rate changes sorted by date
  def variable_rates
    (variable_rate_schedule || {}).sort_by { |date, _| Date.parse(date) }
  end

  # Get the effective interest rate at a specific point in time
  def current_variable_rate(as_of_date = Date.current)
    rates = variable_rates.reverse
    rates.find { |date_str, _| Date.parse(date_str) <= as_of_date }&.last || interest_rate
  end

  # Rebuild the persisted amortization schedule, clearing and re-generating all payment records.
  # Uses a bulk insert rather than one INSERT per payment -- with a 30-year
  # term that's 360 round trips, which is slow enough to matter in an
  # after_save callback running inside the request/response cycle.
  def rebuild_amortization_schedule
    return unless amortizable?

    @amortization_schedule = nil
    now = Time.current
    rows = amortization_schedule.payments.map do |payment_data|
      {
        loan_id: id,
        payment_number: payment_data[:payment_number],
        payment_date: payment_data[:payment_date],
        payment_amount: payment_data[:payment_amount],
        principal_payment: payment_data[:principal_payment],
        interest_payment: payment_data[:interest_payment],
        beginning_balance: payment_data[:beginning_balance],
        ending_balance: payment_data[:ending_balance],
        interest_rate: payment_data[:interest_rate],
        created_at: now,
        updated_at: now
      }
    end

    transaction do
      amortizations.delete_all
      LoanAmortization.insert_all!(rows) if rows.any?
    end
  end

  # Lazily (re)build the persisted schedule if it doesn't exist yet -- a
  # safety net for loans that predate the after_save callback, or whose
  # amortizations were cleared out from under them.
  def ensure_amortization_schedule_current!
    rebuild_amortization_schedule if amortizable? && amortizations.empty?
  end

  private

    # True when a change was just saved that would change the generated
    # schedule, so the persisted amortizations table doesn't silently drift
    # out of sync with the loan's actual terms.
    def amortization_inputs_changed?
      saved_change_to_interest_rate? ||
        saved_change_to_term_months? ||
        saved_change_to_rate_type? ||
        saved_change_to_start_date? ||
        saved_change_to_variable_rate_schedule?
    end

    # Find the next future date when an interest rate change occurs
    def find_next_rate_change_date
      return nil if variable_rate_schedule.blank?
      dates = variable_rate_schedule.keys.map { |d| Date.parse(d) }
      future_dates = dates.select { |d| d > Date.current }
      future_dates.min
    end

    class << self
      def color
        "#D444F1"
      end

      def icon
        "hand-coins"
      end

      def classification
        "liability"
      end
    end
end
