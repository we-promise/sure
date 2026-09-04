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

  # Loans up to 100 years cover any real mortgage, business, or personal loan
  # term while keeping a rebuild's array allocation, exponentiation, and bulk
  # insert bounded. Matches the DB check constraint in
  # db/migrate/20260903150000_add_amortization_bounds_to_loans.rb.
  MAX_TERM_MONTHS = 1200

  has_many :amortizations, class_name: "LoanAmortization", dependent: :destroy

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true
  validates :term_months, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_TERM_MONTHS }, allow_nil: true
  validates :interest_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validate :variable_rate_schedule_entries_are_valid

  before_validation :quantize_variable_rate_schedule

  after_save :enqueue_amortization_rebuild, if: :amortization_inputs_changed?

  def monthly_payment
    amortization_schedule.monthly_payment
  end

  # Memoized per instance (and cleared alongside the calculator cache) so a
  # single check-then-rebuild cycle reads Account's mutable, unlocked
  # valuation/currency once and reuses that exact reading everywhere --
  # otherwise the signature persisted with a schedule could describe a
  # different balance than the one actually used to calculate it if a
  # concurrent Account update lands between the two reads.
  def original_balance
    @original_balance ||= Money.new(account.first_valuation_amount, account.currency)
  end

  def account_opening_anchor_date
    @account_opening_anchor_date ||= account.opening_anchor_date
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
      original_balance.amount.to_s,
      account.currency,
      account_opening_anchor_date.to_s,
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
  # This also removes rows when a loan is no longer amortizable. Mutates, so
  # callers that must not write on a read (e.g. a read-scoped API request)
  # should use #schedule_current? instead and let the background job handle
  # regeneration.
  def ensure_amortization_schedule_current!
    with_lock do
      clear_amortization_schedule_cache!

      unless amortizable?
        amortizations.delete_all if amortizations.exists?
        reset_amortizations_association!
        next
      end

      rebuild_amortization_schedule_locked! unless schedule_current?
    end
  end

  # Read-only freshness check. `rebuild_amortization_schedule_locked!` always
  # replaces every row for a loan in one transaction under the same
  # signature, so the persisted set is current if and only if a row exists
  # with today's signature -- no need to regenerate the schedule just to
  # count it. Backed by the existing loan_id+schedule_signature index.
  def schedule_current?
    return false unless amortizable?
    amortizations.exists?(schedule_signature: amortization_schedule_signature)
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
          algorithm_version: AmortizationSchedule::ALGORITHM_VERSION,
          generated_at: now,
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

    # Enqueues instead of rebuilding inline: a rebuild allocates and inserts
    # up to MAX_TERM_MONTHS rows under a row lock, which shouldn't happen
    # synchronously inside an ordinary save. Deduped per loan via
    # sidekiq-unique-jobs, so a burst of saves collapses to one rebuild.
    def enqueue_amortization_rebuild
      LoanAmortizationRebuildJob.perform_later(id)
    end

    def normalized_rate(rate)
      BigDecimal(rate.to_s)
    rescue ArgumentError, TypeError
      raise ArgumentError, "variable interest rates must be numeric"
    end

    def quantize_variable_rate_schedule
      return unless variable_rate_schedule.is_a?(Hash)

      self.variable_rate_schedule = variable_rate_schedule.transform_values do |rate|
        begin
          BigDecimal(rate.to_s).round(3).to_f
        rescue ArgumentError, TypeError
          rate
        end
      end
    end

    def clear_amortization_schedule_cache!
      @amortization_schedule = nil
      @amortization_schedule_signature = nil
      @original_balance = nil
      @account_opening_anchor_date = nil
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
          if !parsed_rate.finite?
            errors.add(:variable_rate_schedule, "contains a non-numeric rate")
          elsif parsed_rate.negative? || parsed_rate > 100
            errors.add(:variable_rate_schedule, "contains a rate outside the supported 0-100 range")
          end
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
