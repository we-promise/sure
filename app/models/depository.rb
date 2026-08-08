class Depository < ApplicationRecord
  include Accountable

  DEFAULT_SUBTYPE = "checking"

  SUBTYPES = {
    "checking" => { short: "Checking", long: "Checking" },
    "savings" => { short: "Savings", long: "Savings" },
    "hsa" => { short: "HSA", long: "Health Savings Account" },
    "cd" => { short: "CD", long: "Certificate of Deposit" },
    "money_market" => { short: "MM", long: "Money Market" }
  }.freeze

  # Depository subtypes that carry tax-advantaged treatment in the budget /
  # cashflow / income-statement filters (`Family#tax_advantaged_account_ids`,
  # `TaxTreatable#tax_advantaged?`). HSA cash sits here because Plaid routes
  # `depository.hsa` to `Depository` (not `Investment`) via
  # `PlaidAccount::TypeMappable`, so a real-world Plaid-linked HSA cash account
  # was previously invisible to the tax-advantaged filter PR #724 introduced.
  TAX_ADVANTAGED_SUBTYPES = %w[hsa].freeze

  FIXED_RETURN_FREQUENCIES = %w[monthly quarterly annually].freeze

  validates :fixed_return_frequency, inclusion: { in: FIXED_RETURN_FREQUENCIES }, allow_blank: true
  validates :fixed_return_rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :fixed_return_frequency, :fixed_return_start_date, presence: true, if: :fixed_return_rate?
  validate :fixed_return_start_date_cannot_be_in_the_future

  # A fixed-return account pays a known rate that no data provider reports, so
  # Sure credits the interest itself. All three settings are required: without
  # a rate there's nothing to pay, and without a start date and frequency we
  # don't know which periods to pay it for.
  def fixed_return?
    fixed_return_rate.to_d.positive? &&
      fixed_return_frequency.in?(FIXED_RETURN_FREQUENCIES) &&
      fixed_return_start_date.present?
  end

  # A rate on its own would look configured while silently paying nothing, so
  # the other two settings are required alongside it.
  def fixed_return_rate?
    fixed_return_rate.to_d.positive?
  end

  # `TaxTreatable` (the `Account` concern) reads this via `respond_to?` so
  # adding it here transparently flips `Account#tax_advantaged?` for HSA
  # depositories without touching the concern itself.
  #
  # Returns `nil` (not `:taxable`) for ordinary depository subtypes. `nil`
  # already reads as taxable everywhere it matters: `TaxTreatable#taxable?`
  # treats `nil` as taxable and `#tax_advantaged?` excludes it. Returning
  # `nil` also keeps `tax_treatment.present?` false so the header tax badge
  # (`app/views/accounts/show/_header.html.erb`) stays hidden on checking,
  # savings, CD, and money-market accounts that never displayed it before.
  def tax_treatment
    :tax_advantaged if TAX_ADVANTAGED_SUBTYPES.include?(subtype)
  end

  class << self
    def color
      "#875BF7"
    end

    def classification
      "asset"
    end

    def icon
      "landmark"
    end
  end

  private
    def fixed_return_start_date_cannot_be_in_the_future
      return if fixed_return_start_date.blank? || fixed_return_start_date <= Date.current

      errors.add(:fixed_return_start_date, :in_the_future)
    end
end
