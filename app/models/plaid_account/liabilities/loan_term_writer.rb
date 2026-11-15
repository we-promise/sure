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

      # Logged after the rollback so the entry is not rolled back with it.
      report_refusal(loan, present.keys.map(&:to_s), refusal)
    end

    # A fixed loan's rate is its base rate, as before. A variable loan's is
    # decided by the loan: a first sighting sets the base rate, an unchanged
    # rate writes nothing, a change is a row dated `as_of`.
    #
    # Not from an import that stopped for a fresh login: PlaidItem::Importer
    # swallows ITEM_LOGIN_REQUIRED and marks the item, and the sync still
    # processes, so this payload is the previous sync's. Its rate is not a
    # change the bank reported on `as_of`, and dating it would route around a
    # base rate the user has since corrected and locked. The status means
    # "this import" because PlaidItem::Importer#import puts it back to good
    # after a fetch that succeeds.
    #
    # The guard sits after the fixed branch on purpose: a stale fixed rate is
    # the value the last sync already wrote, and a user's correction to it is
    # locked, so rewriting it changes nothing. Only the variable path would
    # turn the stale rate into a new dated row.
    def rate_update(loan, rate)
      return { interest_rate: rate } unless loan.variable_rate_type?
      return nil if plaid_account.plaid_item.requires_update?

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

    # `enrich_attributes` saves with `save`, so a refusal returns false where
    # `update!` raised into PlaidAccount::Processor#process_liabilities's
    # rescue, which sent it to Sentry. Both are kept: the debug log for support,
    # filtered by the connection, and Sentry so a refusal that recurs every
    # sync still shows in error monitoring. The errors are passed in because
    # the loan has been reloaded by the time this runs.
    def report_refusal(loan, attributes, errors)
      message = "Plaid loan terms refused by the model"

      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: message,
        source: self.class.name,
        provider_key: "plaid",
        account: account,
        account_provider: plaid_account.account_provider,
        metadata: {
          plaid_account_id: plaid_account.id,
          attributes: attributes,
          errors: errors
        }
      )

      Sentry.capture_message(message, level: :warning) do |scope|
        scope.set_tags(plaid_account_id: plaid_account.id)
        scope.set_context("plaid_loan_terms", { loan_id: loan.id, attributes: attributes, errors: errors })
      end
    end
end
