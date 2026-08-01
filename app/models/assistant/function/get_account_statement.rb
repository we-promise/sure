# frozen_string_literal: true

class Assistant::Function::GetAccountStatement < Assistant::Function
  include Assistant::Function::StatementVaultSupport

  DOWNLOAD_URL_TTL = 15.minutes

  class << self
    def name
      "get_account_statement"
    end

    def description
      <<~INSTRUCTIONS
        Fetch one Statement Vault document by ID: its identity (SHA-256, filename,
        period), any balances recorded for it, and reconciliation checks against
        the ledger.

        IMPORTANT — reconciliation is usually empty, and its absence means nothing.
        The checks only exist once a human has typed the statement's opening and
        closing balances into the Statement Vault UI. Nothing extracts them from
        the document, so a statement you uploaded through `upload_account_statement`
        comes back with `reconciliation_checks: []` and
        `reconciliation_status: "unavailable"`. That is "nobody has entered the
        figures", NOT "the document agrees with the ledger". Never report an
        unreconciled statement as verified.

        When the balances have been entered, each check compares that figure
        against the account's recorded balance:

        - `opening_balance` / `closing_balance` — the statement's figure vs the ledger's
        - `period_movement` — the change across the period, both sides

        Each reports `matched` or `mismatched` (tolerance: 0.01). A mismatch means
        the ledger and the document disagree — report it, and do not paper over it
        by adjusting the number to fit. Note this is ledger agreement only: nothing
        here verifies that the document's own line items sum to its printed total.
        That parse-integrity check belongs to whatever extracted the figures.

        Also returns a short-lived download URL (valid #{DOWNLOAD_URL_TTL.inspect})
        for the original file when one is attached.

        Example:

        ```
        get_account_statement({ statement_id: "abc123-def456" })
        ```
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "statement_id" ],
      properties: {
        statement_id: {
          type: "string",
          description: "UUID of the statement, as returned by list_account_statements or upload_account_statement."
        }
      }
    )
  end

  def call(params = {})
    return not_a_statement_manager unless statement_manager?

    statement = find_statement(params["statement_id"])

    unless statement&.viewable_by?(user)
      return error("not_found", "No statement found with that ID that this user can view.")
    end

    checks = reconciliation_payload(statement)
    status = statement.reconciliation_status

    {
      success: true,
      statement: statement_payload(statement).merge(
        reconciliation_status: status,
        reconciliation_checks: checks,
        # Spelled out in the payload, not just the tool description: an agent
        # reading only the JSON must not read an empty check list as agreement.
        reconciliation_note: unavailable_note(status),
        download_url: download_url(statement)
      ).compact
    }
  end

  private
    def unavailable_note(status)
      return nil unless status == "unavailable"

      "No reconciliation has been performed: this statement has no opening/closing " \
      "balances recorded, and nothing extracts them from the document. Someone must " \
      "enter them in the Statement Vault UI. This is not evidence that the statement " \
      "agrees with the ledger."
    end

    def reconciliation_payload(statement)
      statement.reconciliation_checks.map do |check|
        {
          check: check[:key],
          statement_amount: check[:statement_amount].to_s,
          ledger_amount: check[:ledger_amount].to_s,
          difference: check[:difference].to_s,
          status: check[:status]
        }
      end
    end

    # Chat and MCP clients render outside the request that produced the record, so
    # the URL has to be absolute. Falls back to nil when no host is configured
    # (e.g. a self-hosted worker with no APP_DOMAIN) rather than handing back a
    # relative path an external agent cannot resolve.
    def download_url(statement)
      return nil unless statement.original_file.attached?

      host_opts = Rails.application.config.action_mailer.default_url_options || {}
      return nil if host_opts[:host].blank?

      Rails.application.routes.url_helpers.rails_blob_url(
        statement.original_file,
        host_opts.merge(disposition: "attachment", expires_in: DOWNLOAD_URL_TTL)
      )
    end
end
