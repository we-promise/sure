# Provides a single, shared IBAN normalization rule used everywhere an IBAN
# is stored or compared in this app (Account, Merchant, EnableBankingAccount,
# EnableBankingEntry::Processor's counterparty IBAN, the rules condition
# filter, transaction search, transfer matching, the family_merchants
# controller's change-detection, and the security backfill task).
#
# A real IBAN is only ever letters and digits (ISO 13616): 2-letter country
# code, 2 check digits, up to 30 alphanumeric characters. Stripping anything
# that isn't a letter or digit -- not just whitespace -- correctly handles
# every formatting style a user might paste in (spaces, dots, dashes,
# tabs/newlines/NBSP from a formatted PDF or bank statement, "DE89.3704...",
# "DE89-3704...", etc.) instead of only catching whitespace and silently
# keeping other separators in the stored value.
#
# A single shared implementation also avoids the normalization drifting out
# of sync between call sites, which previously caused a real bug: Monobank's
# own counter_iban field was normalized differently (or not at all) from the
# rest of the app, so a value that looked identical to a user could silently
# fail to match in rules/search.
#
# Usage as a model concern (adds a before_validation callback):
#   include IbanNormalizable
#
# Usage as a plain utility (rule filters, search, controllers, rake tasks):
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
