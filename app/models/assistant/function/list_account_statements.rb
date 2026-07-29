# frozen_string_literal: true

class Assistant::Function::ListAccountStatements < Assistant::Function
  include Assistant::Function::StatementVaultSupport

  DEFAULT_LIMIT = 25
  MAX_LIMIT = 100

  class << self
    def name
      "list_account_statements"
    end

    def description
      <<~INSTRUCTIONS
        List documents in the family's Statement Vault with their identity and
        provenance: SHA-256, filename, statement period, linked account, and
        review status.

        Use this to answer "which statements do we hold?", to find the document
        backing a figure, to check whether a file is already archived (filter by
        `content_sha256`), or to work the review queue (filter by
        `review_status: "unmatched"` for documents awaiting a human's account
        decision).

        This returns document identity, not document contents. To search inside
        uploaded documents use `search_family_files`; to fetch one statement's
        reconciliation figures and a download link use `get_account_statement`.

        Example:

        ```
        list_account_statements({
          review_status: "unmatched",
          period_start_on_or_after: "2026-01-01"
        })
        ```
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      properties: {
        account_id: {
          type: "string",
          description: "Only statements linked to this account UUID."
        },
        review_status: {
          type: "string",
          enum: AccountStatement.review_statuses.keys,
          description: "unmatched = awaiting a human account decision, linked = attached to an account, rejected = the suggested match was declined."
        },
        content_sha256: {
          type: "string",
          description: "Look up a specific document by the SHA-256 of its contents. Use this to check whether a file is already archived."
        },
        period_start_on_or_after: {
          type: "string",
          description: "ISO 8601 date (YYYY-MM-DD). Only statements whose period ends on or after this date."
        },
        period_end_on_or_before: {
          type: "string",
          description: "ISO 8601 date (YYYY-MM-DD). Only statements whose period starts on or before this date."
        },
        limit: {
          type: "integer",
          description: "Maximum statements to return (default #{DEFAULT_LIMIT}, max #{MAX_LIMIT})."
        }
      }
    )
  end

  def call(params = {})
    return not_a_statement_manager unless statement_manager?

    scope = family.account_statements.includes(:account, :suggested_account).ordered

    if params["account_id"].present?
      return error("invalid_account_id", "account_id must be a UUID.") unless valid_uuid?(params["account_id"])

      scope = scope.where(account_id: params["account_id"])
    end

    if params["review_status"].present?
      status = params["review_status"].to_s
      unless AccountStatement.review_statuses.key?(status)
        return error("invalid_review_status", "review_status must be one of: #{AccountStatement.review_statuses.keys.join(", ")}.")
      end

      scope = scope.where(review_status: status)
    end

    scope = scope.where(content_sha256: params["content_sha256"].to_s.strip) if params["content_sha256"].present?

    if params["period_start_on_or_after"].present?
      date = parse_date(params["period_start_on_or_after"])
      return error("invalid_date", "period_start_on_or_after must be an ISO 8601 date (YYYY-MM-DD).") unless date

      scope = scope.where("period_end_on >= ?", date)
    end

    if params["period_end_on_or_before"].present?
      date = parse_date(params["period_end_on_or_before"])
      return error("invalid_date", "period_end_on_or_before must be an ISO 8601 date (YYYY-MM-DD).") unless date

      scope = scope.where("period_start_on <= ?", date)
    end

    limit = (params["limit"] || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
    # A statement with no account is visible to any statement manager; a linked
    # one follows the account's sharing rules, so filter after the query. Counting
    # before that filter would report statements this user may not know exist, so
    # the page is over-fetched by one and reported as has_more instead.
    rows = scope.limit(limit + 1).to_a
    statements = rows.first(limit).select { |statement| statement.viewable_by?(user) }

    {
      success: true,
      returned: statements.size,
      has_more: rows.size > limit,
      statements: statements.map { |statement| statement_payload(statement) }
    }
  end
end
