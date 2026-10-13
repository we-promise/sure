# The one IBAN normalization rule for every IBAN this app stores (Account,
# Merchant, EnableBankingAccount) and for the places that compare a submitted
# value with a stored one (the family_merchants controller's change
# detection, the data importer and the security backfill task).
#
# A real IBAN is only ever letters and digits (ISO 13616): 2-letter country
# code, 2 check digits, up to 30 alphanumeric characters. Stripping anything
# that isn't a letter or digit -- not just whitespace -- handles every
# formatting style a user might paste in (spaces, dots, dashes,
# tabs/newlines/NBSP from a formatted PDF or bank statement) so equal IBANs
# compare equal in the uniqueness checks.
#
# Usage as a model concern (adds a before_validation callback):
#   include IbanNormalizable
#
# Usage as a plain utility (controllers, importer, rake tasks):
#   IbanNormalizable.normalize(value)
module IbanNormalizable
  extend ActiveSupport::Concern

  def self.normalize(value)
    value.to_s.gsub(/[^a-zA-Z0-9]/, "").upcase.presence
  end

  included do
    before_validation :normalize_iban
  end

  private
    def normalize_iban
      self.iban = IbanNormalizable.normalize(iban)
    end
end
