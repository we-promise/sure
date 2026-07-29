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

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true
  validates :interest_accrual_day,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 31 },
            allow_nil: true
  validates :interest_rate, :interest_accrual_start_date, presence: true, if: :accrue_interest?

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
  # Deliberately not restricted to fixed-rate loans: each charge is derived from
  # the balance outstanding on the accrual date and the rate configured at the
  # time, so a variable or adjustable rate simply takes effect from the next
  # accrual onward.
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

  private
    def resync_account_for_accrual_changes
      return unless saved_changes.keys.intersect?(ACCRUAL_INPUTS)

      # Deliberately not `account&.sync_later`. Reading the has_one here caches a
      # nil association whenever a Loan is saved before its Account exists — the
      # `Account.create!(accountable: Loan.create!(...))` pattern — leaving every
      # later call that needs `account` to see nil on the same instance.
      Account.find_by(accountable_type: "Loan", accountable_id: id)&.sync_later
    end
end
