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

  # Sign convention, asserted once so nothing downstream has to guess:
  # `overdraft_limit` is stored POSITIVE and the balance may fall to its
  # negative. A limit of 400 permits a balance of -400. This returns the floor
  # in balance terms, which is what a projection actually compares against.
  def overdraft_floor
    return 0.to_d if overdraft_limit.nil?

    -overdraft_limit
  end

  # Every recorded overdraft term counts, not just the two headline ones: a
  # holder who entered only the agios rate, or only the fee threshold, has
  # recorded terms, and answering false here drops them from the assistant's
  # account serialization and collapses the form disclosure that holds them.
  OVERDRAFT_TERM_ATTRIBUTES = %i[
    overdraft_limit
    overdraft_interest_rate
    intervention_fee_amount
    intervention_fee_threshold
    intervention_fee_monthly_cap
    intervention_fee_monthly_count_cap
  ].freeze

  def overdraft_terms?
    OVERDRAFT_TERM_ATTRIBUTES.any? { |attribute| public_send(attribute).present? }
  end

  # The fee a bank charges for one payment presented while the account is past
  # its limit. Returns zero rather than nil when the terms are known and the fee
  # does not apply, and nil when the terms were never entered, so a caller can
  # tell "no fee" from "we do not know".
  #
  # `payment_amount` is a magnitude, matching the positive-is-an-expense
  # convention used on entries.
  def intervention_fee_for(payment_amount)
    return nil if intervention_fee_amount.nil?

    threshold = intervention_fee_threshold || 0
    return 0.to_d if payment_amount.to_d <= threshold

    intervention_fee_amount
  end

  # Applies the bank's monthly caps to a run of fees. Both cap forms exist
  # because banks use either, and some use both; whichever binds first wins.
  def capped_monthly_fees(fees)
    fees = fees.map(&:to_d)
    fees = fees.first(intervention_fee_monthly_count_cap) if intervention_fee_monthly_count_cap.present?

    total = fees.sum
    return total if intervention_fee_monthly_cap.blank?

    [ total, intervention_fee_monthly_cap ].min
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
