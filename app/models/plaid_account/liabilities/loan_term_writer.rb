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

      # Enrichable logs the DataEnrichment before it saves, and a refused save
      # does not roll that row back. This transaction does, so provenance never
      # says Plaid supplied a value the loan rejected. `requires_new`, so the
      # rollback holds even when a caller has a transaction open.
      loan.transaction(requires_new: true) do
        loan.enrich_attributes(present, source: "plaid")
        raise ActiveRecord::Rollback if loan.errors.any?
      end
      return if loan.errors.empty?

      names = present.keys.map(&:to_s)
      report_refusal(loan, names)

      # A refusal leaves the rejected values assigned and the errors populated
      # on the in-memory loan. Left there, the next write in the same sync is
      # refused for them, and a later no-op write reports them again.
      loan.restore_attributes(names)
      loan.errors.clear
    end

    # `enrich_attributes` saves with `save`, so a refusal returns false where
    # `update!` raised into PlaidAccount::Processor#process_liabilities's
    # rescue, which sent it to Sentry. Both are kept: the debug log for support,
    # filtered by the connection, and Sentry so a refusal that recurs every
    # sync still shows in error monitoring. `false` alone is not a refusal:
    # Enrichable also returns it when every attribute was locked or unchanged,
    # so only populated errors are reported.
    def report_refusal(loan, attributes)
      message = "Plaid loan terms refused by the model"
      errors = loan.errors.full_messages

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
