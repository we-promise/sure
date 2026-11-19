# Monobank does not categorise transactions; it reports the merchant's MCC (`mcc`, plus
# `originalMcc` when the acquirer rewrote it). That is the only categorisation signal
# available, so the shared ISO 18245 table is used directly here -- see
# Transactions::MccTaxonomy for the groupings and the codes left deliberately unmapped.
module MonobankAccount::Transactions::CategoryTaxonomy
  include Transactions::MccTaxonomy
end
