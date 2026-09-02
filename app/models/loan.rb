require "digest"

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
  validate :variable_rate_schedule_entries_are_valid

  after_save :rebuild_amortization_schedule, if: :amortization_inputs_changed?

  def monthly_payment
    amortization_schedule.monthly_payment
  end

  def original_balance
    Money.new(account.first_valuation_amount, account.currency)
  end

  # Recreate the calculator when any Loan or Account input changes. Account
  # changes do not fire Loan callbacks, so the signature also protects callers
  # that hold onto a Loan instance across an Account update.
  def amortization_schedule
    signature = amortization_schedule_signature
    if @amortization_schedule.nil? || @amortization_schedule_signature != signature
      @amortization_schedule = AmortizationSchedule.new(self)
      @amortization_schedule_signature = signature
    end
    @amortization_schedule
  end

  def amortizable?
    amortization_schedule.amortizable?
  end

  # Add or update a variable interest rate change on a specific date.
  def add_variable_rate_change(date, rate)
    effective_date = Date.iso8601(date.to_s)
    normalized_rate = BigDecimal(rate.to_s)
    raise ArgumentError, "rate must be a finite number" unless normalized_rate.finite?

    self.variable_rate_schedule = (variable_rate_schedule || {}).stringify_keys.merge(
      effective_date.iso8601 => rate
    )
    save!
  end

  def variable_rates
    (variable_rate_schedule || {}).sort_by { |date, _| Date.iso8601(date.to_s) }
  end

  def current_variable_rate(as_of_date = Date.current)
    rate = variable_rates.reverse.find do |date_str, _|
      Date.iso8601(date_str.to_s) <= as_of_date
    end&.last

    rate.nil? ? interest_rate : normalized_rate(rate)
  end

  # This is derived rather than stored because a persisted "next" date becomes
  # stale when the current date passes it.
  def next_rate_change_date
    return nil unless rate_type == "variable"

    variable_rates.map { |date, _| Date.iso8601(date.to_s) }.find { |date| date > Date.current }
  end

  # Fingerprint every input used by AmortizationSchedule. It lets persisted
  # rows be invalidated when the source change happens on Account data.
  def amortization_schedule_signature
    return nil unless account

    Digest::SHA256.hexdigest([
      AmortizationSchedule::ALGORITHM_VERSION,
      account.id,
      account.first_valuation_amount.amount.to_s,
      account.currency,
      account.opening_anchor_date.to_s,
      interest_rate.to_s,
      term_months.to_s,
      rate_type.to_s,
      start_date&.iso8601,
      variable_rates.map { |date, rate| [ date.to_s, normalized_rate(rate).to_s ] }
    ].to_json)
  end

  # Rebuild the persisted amortization schedule under a loan lock so readers
  # never observe a delete/insert gap and concurrent rebuilds serialize.
  def rebuild_amortization_schedule
    with_lock { rebuild_amortization_schedule_locked! }
  end

  # Lazily build or replace the persisted schedule when it is missing or stale.
  # This also removes rows when a loan is no longer amortizable.
  def ensure_amortization_schedule_current!
    with_lock do
      clear_amortization_schedule_cache!

      unless amortizable?
        amortizations.delete_all if amortizations.exists?
        reset_amortizations_association!
        next
      end

      schedule = amortization_schedule
      signature = amortization_schedule_signature
      matching_rows = amortizations.where(schedule_signature: signature).count
      current = matching_rows == schedule.payment_count && amortizations.count == schedule.payment_count
      rebuild_amortization_schedule_locked! unless current
    end
  end

  private

    def rebuild_amortization_schedule_locked!
      clear_amortization_schedule_cache!

      unless amortizable?
        amortizations.delete_all if amortizations.exists?
        reset_amortizations_association!
        return
      end

      schedule = amortization_schedule
      signature = amortization_schedule_signature
      now = Time.current
      rows = schedule.payments.map do |payment_data|
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
          schedule_signature: signature,
          created_at: now,
          updated_at: now
        }
      end

      transaction do
        amortizations.delete_all
        LoanAmortization.insert_all!(rows) if rows.any?
      end
      reset_amortizations_association!
    end

    def amortization_inputs_changed?
      saved_change_to_interest_rate? ||
        saved_change_to_term_months? ||
        saved_change_to_rate_type? ||
        saved_change_to_start_date? ||
        saved_change_to_variable_rate_schedule?
    end

    def normalized_rate(rate)
      BigDecimal(rate.to_s)
    rescue ArgumentError, TypeError
      raise ArgumentError, "variable interest rates must be numeric"
    end

    def clear_amortization_schedule_cache!
      @amortization_schedule = nil
      @amortization_schedule_signature = nil
    end

    def reset_amortizations_association!
      association(:amortizations).reset
    end

    def variable_rate_schedule_entries_are_valid
      return if variable_rate_schedule.blank?

      unless variable_rate_schedule.is_a?(Hash)
        errors.add(:variable_rate_schedule, "must be a JSON object")
        return
      end

      variable_rate_schedule.each do |date, rate|
        begin
          Date.iso8601(date.to_s)
        rescue ArgumentError
          errors.add(:variable_rate_schedule, "contains an invalid effective date")
        end

        begin
          parsed_rate = BigDecimal(rate.to_s)
          errors.add(:variable_rate_schedule, "contains a non-numeric rate") unless parsed_rate.finite?
        rescue ArgumentError, TypeError
          errors.add(:variable_rate_schedule, "contains a non-numeric rate")
        end
      end
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
