# The rule set a subtype brings with it: what an account of this type and
# subtype gets by default, so new behaviour keyed off a subtype does not end
# up as another scattered constant.
#
# Built by `Accountable.rules_for(subtype)` on each accountable class.
Accountable::Rules = Data.define(:accountable_type, :subtype, :liquidity, :tax_treatment)
