# frozen_string_literal: true

class Assistant::Function::GetStatementCoverage < Assistant::Function
  include Assistant::Function::StatementVaultSupport

  class << self
    def name
      "get_statement_coverage"
    end

    def description
      <<~INSTRUCTIONS
        Report, month by month, which statements the family actually holds for an
        account in a given year — the document-coverage map behind the numbers.

        Each month comes back with one status:

        - `covered` — a linked statement covers the month. This means a DOCUMENT
          EXISTS, not that it agrees with the ledger: most statements have no
          balances entered, so there is nothing to reconcile and they still count
          as covered. Check `reconciliation_status` on the month before saying a
          month is verified.
        - `mismatched` — a statement covers it, but its balances disagree with the ledger
        - `missing` — no statement on record; the month's figures have no document behind them
        - `ambiguous` — a statement was suggested for this account but nobody has confirmed the link
        - `duplicate` — two or more linked statements overlap the same month
        - `not_expected` — outside the account's expected statement range

        Each covered month also carries `reconciliation_status`: `matched` when
        every statement in it reconciles against the ledger, `mismatched` when one
        disagrees, and `unavailable` when nobody has entered the balances — which
        is the common case.

        Use it before asserting anything about a period: "no statement on record"
        is a legitimate and necessary answer, and is very different from "the
        balance was zero". Use it to tell the user exactly which documents to go
        find.

        Example:

        ```
        get_statement_coverage({ account_id: "abc123-def456", year: 2026 })
        ```
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "account_id" ],
      properties: {
        account_id: {
          type: "string",
          description: "UUID of the account to report coverage for."
        },
        year: {
          type: "integer",
          description: "Calendar year. Defaults to the most recent year with expected statements."
        }
      }
    )
  end

  def call(params = {})
    return not_a_statement_manager unless statement_manager?

    account_id = params["account_id"].to_s
    return error("invalid_account_id", "account_id must be a UUID.") unless valid_uuid?(account_id)

    # accessible_by, not writable_by, is deliberate: this reports which documents
    # exist for an account and writes nothing. Someone with read access to an
    # account is entitled to know which of its statements are on file. Do not
    # "tighten" this to writable_by — that would hide gaps from the people who
    # can see the figures those gaps sit behind.
    account = family.accounts.accessible_by(user).find_by(id: account_id)
    return error("account_not_found", "No accessible account found with that ID.") unless account

    coverage = AccountStatement::Coverage.for_year(account, params["year"])

    {
      success: true,
      account: account_ref(account),
      year: coverage.selected_year,
      available_years: coverage.available_years,
      summary: coverage.summary_counts,
      months: coverage.months.map { |month| month_payload(month) }
    }
  end

  private
    def month_payload(month)
      {
        month: month.date.strftime("%Y-%m"),
        status: month.status,
        # A month is "covered" on document presence alone — an unreconciled
        # statement is not mismatched, so it lands in `covered`. Without this
        # field an agent cannot tell "the ledger agrees" from "nobody checked".
        reconciliation_status: reconciliation_status_for(month),
        statement_ids: month.statements.map(&:id),
        unconfirmed_statement_ids: month.ambiguous_statements.map(&:id)
      }.compact_blank
    end

    def reconciliation_status_for(month)
      return nil if month.statements.empty?

      statuses = month.statements.map(&:reconciliation_status).uniq
      return "mismatched" if statuses.include?("mismatched")
      return "unavailable" if statuses.include?("unavailable")

      "matched"
    end
end
