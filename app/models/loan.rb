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

  has_many :rate_changes, -> { order(:effective_date) },
           class_name: "Loan::RateChange", dependent: :destroy, inverse_of: :loan
  accepts_nested_attributes_for :rate_changes, allow_destroy: true, reject_if: :all_blank

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true
  validates :interest_accrual_day,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 31 },
            allow_nil: true
  validates :interest_rate, :interest_accrual_start_date, presence: true, if: :accrue_interest?
  # Loan::RateChange has a per-loan uniqueness validation, but that only catches
  # collisions against already-persisted rows. Two *new* rate changes sharing a
  # date in one nested-attributes save both pass it and then hit the DB unique
  # index, which surfaces as an unrescued RecordNotUnique (500). Catch that here,
  # where the whole in-memory set is visible.
  validate :rate_change_dates_are_distinct

  # Re-accrue whenever an input to the schedule changes. Nothing else triggers a
  # sync on this path — AccountableResource#update only syncs when the account
  # balance changed — so without this the user would flip the toggle, see
  # nothing happen, and get a pile of backdated entries whenever the daily
  # SyncAllJob next ran.
  after_save_commit :resync_account_for_accrual_changes

  ACCRUAL_INPUTS = %w[
    accrue_interest interest_rate interest_accrual_day interest_accrual_start_date
  ].freeze

  # Whether Loan::InterestAccrual should post monthly interest charges to this
  # account so that payments reduce principal only.
  #
  # Each charge is derived from the balance actually outstanding on the accrual
  # date, so overpayments, missed payments and irregular schedules self-correct
  # on the next accrual without any per-period schedule to maintain.
  #
  # Variable and adjustable rates are supported through effective-dated
  # `rate_changes`: the base `interest_rate` applies from origination and each
  # change resets the rate from its `effective_date` forward, so an ARM reset
  # reprices only periods on or after the reset — the earlier periods keep the
  # rate the lender actually charged (see #interest_rate_on). Editing the base
  # `interest_rate` itself still reprices the whole history, which is the correct
  # behavior for correcting a mis-entered origination rate.
  #
  # Linked accounts are excluded here rather than at the call sites: a linked
  # account is anchored to the principal its provider reports, so a replay from
  # origination has no reliable starting point.
  def accrues_interest?
    accrue_interest? &&
      interest_rate.present? && interest_rate.positive? &&
      interest_accrual_start_date.present? &&
      account.present? && account.unlinked?
  end

  def monthly_interest_rate
    return nil if interest_rate.blank?

    interest_rate.to_d / 100 / 12
  end

  # The annual interest rate (percent) in effect on the given date: the most
  # recent effective-dated change on or before it, falling back to the base
  # `interest_rate` for dates before the first change.
  def interest_rate_on(date)
    applicable = rate_changes.select { |rc| rc.effective_date.present? && rc.effective_date <= date }
    applicable.max_by(&:effective_date)&.rate || interest_rate
  end

  # The monthly rate to charge on the given date, honoring rate changes. Nil when
  # no rate is configured.
  def monthly_interest_rate_on(date)
    rate = interest_rate_on(date)
    return nil if rate.blank?

    rate.to_d / 100 / 12
  end

  def accrued_interest_entries
    return Entry.none if account.nil?

    account.entries.where(source: Loan::InterestAccrual::SOURCE)
  end

  def accrued_interest_total
    Money.new(accrued_interest_entries.sum(:amount), account&.currency || "USD")
  end

  def monthly_payment
    return nil if term_months.nil? || interest_rate.nil? || rate_type.nil? || rate_type != "fixed"
    return Money.new(0, account.currency) if account.loan.original_balance.amount.zero? || term_months.zero?

    annual_rate = interest_rate / 100.0
    monthly_rate = annual_rate / 12.0

    if monthly_rate.zero?
      payment = account.loan.original_balance.amount / term_months
    else
      payment = (account.loan.original_balance.amount * monthly_rate * (1 + monthly_rate)**term_months) / ((1 + monthly_rate)**term_months - 1)
    end

    Money.new(payment.round, account.currency)
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

  # Enqueue a sync so Loan::InterestAccrual reconciles the generated entries.
  # Public because Loan::RateChange calls it on commit — a rate change alters the
  # derived balance but is a child row, so it never appears in the loan's own
  # `saved_changes` and would otherwise never trigger a resync.
  #
  # Deliberately not `account&.sync_later`. Reading the has_one here caches a nil
  # association whenever a Loan is saved before its Account exists — the
  # `Account.create!(accountable: Loan.create!(...))` pattern — leaving every
  # later call that needs `account` to see nil on the same instance.
  def resync_for_accrual!
    Account.find_by(accountable_type: "Loan", accountable_id: id)&.sync_later
  end

  private
    def resync_account_for_accrual_changes
      return unless saved_changes.keys.intersect?(ACCRUAL_INPUTS)

      resync_for_accrual!
    end

    def rate_change_dates_are_distinct
      dates = rate_changes.reject(&:marked_for_destruction?).filter_map(&:effective_date)
      return if dates.size == dates.uniq.size

      errors.add(:base, "Rate change effective dates must be unique")
    end
end
