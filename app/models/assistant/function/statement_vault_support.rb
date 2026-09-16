# frozen_string_literal: true

# Shared plumbing for the Statement Vault tools. The vault is reachable from the
# web UI through AccountStatementsController, which enforces the manager role and
# per-account permissions with before_actions. MCP tool calls never pass through
# a controller, so every tool re-checks the same rules here rather than trusting
# that the caller came from a gated surface.
module Assistant::Function::StatementVaultSupport
  private
    def statement_manager?
      AccountStatement.statement_manager?(user)
    end

    def not_a_statement_manager
      error(
        "forbidden",
        "This user is not allowed to manage the Statement Vault. Statement access requires an admin or member role."
      )
    end

    def find_statement(id)
      return nil unless id.present? && valid_uuid?(id)

      family.account_statements.find_by(id: id)
    end

    # Identity and provenance first: the fields an agent needs to cite a document
    # and decide whether to fetch it. Excerpts are the vector store's job.
    def statement_payload(statement)
      {
        id: statement.id,
        filename: statement.filename,
        content_sha256: statement.content_sha256,
        content_type: statement.content_type,
        byte_size: statement.byte_size,
        period_start_on: statement.period_start_on&.iso8601,
        period_end_on: statement.period_end_on&.iso8601,
        currency: statement.statement_currency,
        opening_balance: statement.opening_balance&.to_s,
        closing_balance: statement.closing_balance&.to_s,
        review_status: statement.review_status,
        account: account_ref(statement.account),
        suggested_account: account_ref(statement.suggested_account),
        match_confidence: statement.match_confidence&.to_f,
        institution_name_hint: statement.institution_name_hint,
        account_last4_hint: statement.account_last4_hint,
        uploaded_at: statement.created_at.iso8601
      }.compact
    end

    def account_ref(account)
      return nil unless account

      { id: account.id, name: account.name, currency: account.currency }
    end

    def error(key, message, extras = {})
      { success: false, error: key, message: message }.merge(extras)
    end

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
end
