class LoanExtraRepayment < ApplicationRecord
  # One extra repayment inside a scenario: either a single dated amount, or a
  # recurring one with a cadence.
  #
  # Contract C6 -- EXACT-DATE SEMANTICS. An extra repayment takes effect at the
  # end of its OWN effective date: the balance drops that day, and subsequent
  # days accrue on the reduced balance. Payment dates never defer it. An
  # earlier draft of this rule said "applies at the next scheduled payment",
  # which contradicts the daily-accrual model the engine now runs on
  # (architecture-review finding F1) -- under daily accrual, deferring a
  # payment to the next cycle silently charges interest the borrower did not
  # owe.
  KINDS = %w[one_off recurring].freeze

  # Materialised to EXACT DATES, never to a monthly-equivalent figure. A $500
  # weekly repayment is 52 balance reductions a year, not 12 of $2,166.67: the
  # two differ in interest, and the difference is the whole point of modelling
  # a weekly repayment.
  FREQUENCIES = %w[weekly fortnightly monthly quarterly yearly].freeze

  belongs_to :loan_scenario

  validates :kind, inclusion: { in: KINDS }
  validates :amount, numericality: { greater_than: 0 }
  validates :frequency, inclusion: { in: FREQUENCIES }, allow_nil: true
  validates :interval, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  validate :columns_match_kind
  validate :end_date_follows_start

  def one_off?
    kind == "one_off"
  end

  def recurring?
    kind == "recurring"
  end

  private

    # Mirrors the DB check constraint. The database is the guarantee; this is
    # here so the form can say what is wrong instead of raising a
    # StatementInvalid at the user.
    def columns_match_kind
      if one_off?
        errors.add(:occurs_on, :blank) if occurs_on.blank?
        errors.add(:frequency, :present) if frequency.present?
      elsif recurring?
        errors.add(:frequency, :blank) if frequency.blank?
        errors.add(:occurs_on, :present) if occurs_on.present?
      end
    end

    def end_date_follows_start
      return if starts_on.blank? || ends_on.blank?

      errors.add(:ends_on, :invalid) if ends_on < starts_on
    end
end
