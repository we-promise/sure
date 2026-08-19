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
end
