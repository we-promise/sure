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

  # The rate types the form offers. They are not the only ones a loan can
  # carry: PlaidAccount::Liabilities::MortgageProcessor writes Plaid's raw
  # `interest_rate.type` straight through ("arm", among others), and a loan
  # whose rate can move is variable whatever the provider's word for it.
  # So the predicates below read the column as: "fixed" is fixed, any other
  # non-blank value is variable, and blank says nothing -- such a loan is
  # not amortizable and gets what it got before schedules existed: no
  # schedule, no tab. VARIABLE_RATE_TYPES is the form's vocabulary only,
  # for the rate-change editor to know which of its options to open for.
  FIXED_RATE_TYPE = "fixed".freeze
  VARIABLE_RATE_TYPES = %w[variable adjustable].freeze

  # An annual percentage, matching the bound the rate-change input declares.
  MAX_INTEREST_RATE = 100

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true
  # The form caps the date picker at today; this is the same bound where a
  # crafted request cannot skip it. A loan drawn down in the future has no
  # history to chart and would schedule a first payment months away while
  # charging a month's interest for the gap.
  validates :start_date, comparison: { less_than_or_equal_to: -> { Date.current } }, allow_nil: true

  # What the borrower put in up front. Not part of the amortisation -- the loan
  # amortises what was actually lent -- but it is what makes leverage readable:
  # a 20,000 deposit against an 80,000 loan is a different position from the
  # same loan against 5,000.
  validates :down_payment, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  validates :insurance_rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :insurance_rate_type, inclusion: { in: Loan::Insurance::RATE_TYPES }, allow_nil: true

  # How much was borrowed for every unit the borrower put in. Nil without a
  # down payment recorded: a loan with no deposit is not infinitely leveraged,
  # it is a loan whose leverage nobody has told us.
  LEVERAGE_BANDS = {
    conservative: 0..4,
    moderate: 4..8,
    high: 8..
  }.freeze

  # The contracted repayment, for a loan that has exactly one.
  #
  # Deliberately still nil for a variable loan even though it now has a
  # schedule: such a loan does not HAVE a single monthly payment, and quoting
  # the one it opened with would be a stale figure presented as a current one.
  # Answering it properly means re-amortising today's balance at today's rate,
  # which needs the projection this engine does not yet carry.
  def monthly_payment
    return nil if term_months.nil? || interest_rate.nil? || rate_type.nil? || rate_type != FIXED_RATE_TYPE
    # Non-positive, not just zero: `amortizable?` rejects both, so anything that
    # slips past here would fall through to a nil schedule instead of a payment.
    return Money.new(0, account.currency) if original_balance.amount <= 0 || term_months <= 0

    amortization_schedule&.periodic_payment
  end

  # A loan can be amortised once we know what was borrowed, at what rate, and
  # over how long.
  #
  # Variable loans are included. They were excluded while a schedule could only
  # be built off a single rate -- "a schedule built off today's rate would be
  # fiction" -- but the schedule now re-amortises at each recorded rate change,
  # so the objection no longer holds. A variable loan with no changes recorded
  # yet simply runs at its base rate, which is what it is actually doing.
  def amortizable?
    # `account` first: original_balance reads through it, and a Loan can exist
    # without one (Loan.new in a form, a fixture built in isolation). #2984's
    # `rate_type == "fixed"` guard happened to short-circuit before that read;
    # widening the rate types removed the accident, so the requirement is
    # stated rather than relied upon.
    account.present? &&
      rate_type.present? &&
      interest_rate.present? &&
      term_months.to_i.positive? &&
      term_months.to_i <= Loan::Simulator::MAX_PERIODS &&
      original_balance.amount.positive?
  end

  private def rate_changes_must_be_parseable
    Array(invalid_rate_changes).each do |row|
      errors.add(:base, I18n.t("activerecord.errors.models.loan.invalid_rate_change"))
      break
    end
  end

  private def rate_changes_must_not_precede_origination
    errors.add(:base, :rate_change_before_origination) if rate_changes_precede_origination?
  end

  private def rate_changes_precede_origination?
    return false unless variable_rate_type?
    rate_changes = variable_rates
    return false if rate_changes.empty?

    loan_origination_date = start_date
    unless loan_origination_date.present?
      # Do not call `account` here. Loan validations can run before a separate
      # Account is attached; caching that missing has_one result leaves the
      # later persisted Loan unable to see its Account through the association.
      loan_account = association(:account).target || association(:account).scope.first
      return false unless loan_account

      loan_origination_date = loan_account.first_valuation&.date || loan_account.opening_anchor_date
    end

    loan_origination_date.present? && rate_changes.any? { |date, _rate| date < loan_origination_date }
  end

  # Whether this loan's rate can move over its life. The one place the answer
  # is defined -- callers must not compare rate_type to a string. Anything
  # non-blank that is not "fixed" counts, so a provider's own vocabulary is
  # variable rather than unknown (see the constants above).
  def variable_rate_type?
    rate_type.present? && rate_type != FIXED_RATE_TYPE
  end

  # Recorded rate changes as [Date, BigDecimal] pairs, oldest first. The one
  # place the column is parsed: RateResolver and the form rows read these
  # pairs rather than the raw JSON, so every reader agrees on what a row means.
  def variable_rates
    (variable_rate_schedule || {})
      .map { |date, rate| [ Date.iso8601(date.to_s), BigDecimal(rate.to_s) ] }
      .sort_by(&:first)
  end

  # The rate in force on a given date: the latest change effective on or before
  # it, falling back to the loan's own rate before any change applies. One
  # implementation of that lookup, RateResolver's, so the Overview tab and the
  # schedule cannot disagree about which rate a date carries.
  def current_variable_rate(as_of = Date.current)
    RateResolver.for(self).accrual_rate_for(as_of)
  end

  # Rows the form submitted that could not be parsed. Kept so the save can be
  # rejected and the form re-rendered with what the user actually typed --
  # dropping them silently loses a typo'd row between submit and redisplay,
  # and the user is never told which one went.
  attr_reader :invalid_rate_changes

  validate :rate_changes_must_be_parseable
  validate :rate_changes_must_not_precede_origination

  # Assembles variable_rate_schedule from the form's rows.
  #
  # Keyed by effective date, so re-entering a date replaces that row rather
  # than adding a second one for the same day -- two rates in force on one date
  # is not a state the schedule can represent, and silently keeping both would
  # make which one wins depend on hash ordering.
  #
  # A submission from the form always carries its hidden sentinel, a bare
  # `rate_changes[]` with no value. Rack parses that as "" and strong
  # parameters drop it, so what arrives here when the user removed every row
  # is an empty array -- which correctly clears the schedule. Absent the
  # sentinel, removing the last row would send no `rate_changes` key at all,
  # nested assignment would never call this, and the removed rows would stay
  # persisted. Blank rows that do reach this method (a row the user added and
  # left empty) are skipped for the same reason.
  def rate_changes=(rows)
    invalid = []

    parsed = Array(rows).each_with_object({}) do |row, acc|
      next unless row.respond_to?(:[]) && !row.is_a?(String)

      date = row[:effective_date].presence || row["effective_date"].presence
      rate = row[:rate].presence || row["rate"].presence
      next if date.blank? && rate.blank?

      begin
        raise ArgumentError, "incomplete" if date.blank? || rate.blank?

        # The form's own input already declares `min="0" max="100"`, so this is
        # the same contract enforced where a crafted PATCH cannot skip it. A
        # negative or absurd rate parses perfectly well and then produces a
        # schedule nobody can act on, which is worse than a rejected row.
        parsed_rate = BigDecimal(rate.to_s)
        unless parsed_rate.finite? && parsed_rate >= 0 && parsed_rate <= MAX_INTEREST_RATE
          raise ArgumentError, "rate out of range"
        end

        # ISO 8601 only, as variable_rates reads it back. Date.parse would
        # accept "1" as the first of the current month.
        acc[Date.iso8601(date.to_s).iso8601] = parsed_rate.to_s("F")
      rescue ArgumentError, TypeError, Date::Error, FloatDomainError
        invalid << { effective_date: date.to_s, rate: rate.to_s }
      end
    end

    @invalid_rate_changes = invalid
    self.variable_rate_schedule = parsed
  end

  # The form reaches this record through Account's nested attributes, which
  # validate it only when it has changes. Resubmitting the stored rows plus a
  # typo'd one leaves `variable_rate_schedule` equal to its stored value, so
  # without this the account saved, the typo'd row vanished, and the
  # validation above only fired when some other field happened to change.
  #
  # Autosave asks this on every save of the parent Account. The origination
  # check can load the Account and its first valuation, but only for a variable
  # loan that has recorded rate changes and no start date; every other loan
  # answers from its own attributes.
  def changed_for_autosave?
    super || invalid_rate_changes.present? || rate_changes_precede_origination?
  end

  # Form rows, in a shape the form can render without parsing anything.
  #
  # Rendered for every rate type, including fixed: switching a loan to fixed
  # leaves its recorded changes in the column, `current_variable_rate` ignores
  # them, and the form hides and disables the section. They are retained rather
  # than deleted so switching back reveals them, and a save then resubmits them
  # instead of the sentinel alone, which would clear them.
  #
  # Invalid rows come back too, so a rejected save redisplays what was typed.
  def rate_change_rows
    variable_rates.map { |date, rate| { effective_date: date.iso8601, rate: rate.to_s("F") } } +
      Array(invalid_rate_changes)
  end

  def amortization_schedule
    @amortization_schedule ||= AmortizationSchedule.for(self)
  end

  # The columns AmortizationSchedule.for reads from the loan itself. Assigning
  # any of them drops the memoised schedule, as reload does, so a read after the
  # change answers with the new terms rather than the ones it was built from.
  SCHEDULE_INPUTS = %i[interest_rate term_months rate_type start_date variable_rate_schedule].freeze

  SCHEDULE_INPUTS.each do |input|
    define_method(:"#{input}=") do |value|
      @amortization_schedule = nil
      @insurance = nil
      super(value)
    end
  end

  # The premium is charged against the schedule, so it goes stale for both its
  # own inputs and the schedule's.
  INSURANCE_INPUTS = %i[insurance_rate insurance_rate_type].freeze

  INSURANCE_INPUTS.each do |input|
    define_method(:"#{input}=") do |value|
      @insurance = nil
      super(value)
    end
  end

  def reload(*)
    @amortization_schedule = nil
    @insurance = nil
    super
  end

  # The insurance policy charged alongside this loan's instalments, or nil when
  # no premium is recorded. Read #total_insurance for a figure that is always
  # money.
  def insurance
    @insurance ||= Loan::Insurance.for(self)
  end

  def total_insurance
    insurance&.total || Money.new(0, account.currency)
  end

  # Everything the loan costs the borrower: what was borrowed, the interest on
  # it, and the premium charged alongside. Nil when there is no schedule to
  # read an interest figure from, because a cost without interest in it would
  # understate the loan rather than decline to answer.
  def total_cost
    schedule = amortization_schedule
    return nil if schedule.nil?

    original_balance + schedule.total_interest + total_insurance
  end

  def initial_leverage_ratio
    return nil unless down_payment&.positive?

    original_balance.amount.fdiv(down_payment)
  end

  def leverage_band
    ratio = initial_leverage_ratio
    return nil if ratio.nil?

    LEVERAGE_BANDS.find { |_band, range| range.cover?(ratio) }&.first
  end

  # The date the loan was drawn down. Recorded explicitly when the borrower
  # knows it -- a loan is often drawn down before the account tracking it is
  # created -- and otherwise taken from the account's first valuation (the
  # opening balance), falling back to the opening anchor.
  def origination_date
    start_date || account.first_valuation&.date || account.opening_anchor_date
  end

  def original_balance
    Money.new(account.first_valuation_amount, account.currency)
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
