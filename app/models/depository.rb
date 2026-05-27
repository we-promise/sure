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

  # Mirrors `Investment#tax_treatment` / the `cryptos.tax_treatment` enum.
  # `TaxTreatable` (the `Account` concern) reads this via `respond_to?` so
  # adding it here transparently flips `Account#tax_advantaged?` for HSA
  # depositories without touching the concern itself.
  def tax_treatment
    TAX_ADVANTAGED_SUBTYPES.include?(subtype) ? :tax_advantaged : :taxable
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
