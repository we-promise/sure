# The rule set a subtype brings with it: what an account of this type and
# subtype gets by default. One place to read it, so the account page can show
# which rules apply and where each comes from ("Details"), and so new
# behaviour keyed off a subtype does not end up as another scattered constant.
#
# Built by `Accountable.rules_for(subtype)` on each accountable class.
class Accountable::Rules < Data.define(:accountable_type, :subtype, :liquidity, :tax_treatment)
  # Locked accounts carry a release date (term deposit, building savings).
  def release_date?
    liquidity == "locked"
  end

  # Tax-advantaged accounts stay out of budget and cash flow
  # (Family#tax_advantaged_account_ids).
  def counts_in_budget?
    !tax_treatment.in?(%i[tax_deferred tax_exempt tax_advantaged])
  end
end
