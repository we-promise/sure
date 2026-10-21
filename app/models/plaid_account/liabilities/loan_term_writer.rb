# The one write path for a loan's terms from a Plaid payload, shared by the
# mortgage and student-loan processors.
#
# Both used to call `loan.update!` straight from the payload, which:
#
# - overwrote a value the user corrected on the loan form, which
#   `Account#lock_saved_attributes!` had locked;
# - recorded no provenance, so nothing said the value was Plaid's;
# - blanked a stored value whenever the payload omitted the field, because
#   the omission arrived as nil.
#
# `Enrichable#enrich_attributes` answers the first two, as it already does for
# `RedbarkAccount::LoanDetailsProcessor#write`; `compact` answers the third.
#
# A variable loan's new rate is a row in `variable_rate_schedule` dated to the
# sync's `as_of`, which each including processor supplies, rather than a new
# base rate (Loan#variable_rate_update_for).
module PlaidAccount::Liabilities::LoanTermWriter
  extend ActiveSupport::Concern

  private
    # Only nil means "the payload did not say". A rate of exactly 0 is a real
    # figure for an interest-free loan and is written like any other.
    def write_loan_terms(**attrs)
      loan = account&.loan
      return if loan.nil?

      present = attrs.compact
      return if present.empty?

      terms = present.except(:interest_rate)
      rate = present[:interest_rate]

      # Two saves: the other terms first, so a payload that reclassifies the
      # loan is applied before its rate is judged, then the rate. They land
      # together or not at all, as the single save did.
      #
      # Enrichable logs the DataEnrichment before it saves, and a refused save
      # does not roll that row back. This transaction does, so provenance never
      # says Plaid supplied a value the loan rejected. `requires_new`, so the
      # rollback holds even when a caller has a transaction open.
      refusal = nil
      loan.transaction(requires_new: true) do
        refusal = enrich(loan, terms) || (rate.nil? ? nil : enrich(loan, rate_update(loan, rate)))
        raise ActiveRecord::Rollback if refusal
      end
      return if refusal.nil?

      # A refusal leaves the rejected values assigned and the errors populated
      # on the in-memory loan, and a rolled-back first save leaves its values
      # there too. Left in place, the next write in the same sync is refused
      # for them, and a later no-op write reports them again.
      loan.reload
      loan.errors.clear

      # `enrich_attributes` saves with `save`, so a refusal returns false where
      # `update!` raised into PlaidAccount::Processor#process_liabilities's
      # rescue. Without this the failure would be silent. Logged after the
      # rollback so the entry is not rolled back with it.
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Plaid loan terms refused by the model",
        source: self.class.name,
        provider_key: "plaid",
        account: account,
        metadata: {
          plaid_account_id: plaid_account.id,
          attributes: present.keys.map(&:to_s),
          errors: refusal
        }
      )
    end

    # A fixed loan's rate is its base rate, as before. A variable loan's is
    # decided by the loan: a first sighting sets the base rate, an unchanged
    # rate writes nothing, a change is a row dated `as_of`.
    def rate_update(loan, rate)
      return { interest_rate: rate } unless loan.variable_rate_type?

      loan.variable_rate_update_for(rate, as_of: as_of)
    end

    # Writes through Enrichable and returns nil, or the model's error messages
    # when it refused them. `false` from Enrichable alone is not a refusal: it
    # also means every attribute was locked or unchanged.
    def enrich(loan, attrs)
      return nil if attrs.blank?

      loan.enrich_attributes(attrs, source: "plaid")
      loan.errors.empty? ? nil : loan.errors.full_messages
    end
end
