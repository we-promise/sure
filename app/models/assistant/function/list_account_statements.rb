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

        There is no cursor or offset. `has_more: true` means the result was
        truncated — raise `limit` (up to #{MAX_LIMIT}) or narrow the filters to see
        the rest; paging forward is not possible.

        Example:

        ```
        list_account_statements({
          review_status: "unmatched",
          overlapping_from: "2026-01-01"
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
          description: "Look up a specific document by the SHA-256 of its contents (hex; case-insensitive). Use this to check whether a file is already archived."
        },
        overlapping_from: {
          type: "string",
          description: "ISO 8601 date (YYYY-MM-DD). Only statements whose period overlaps this date or later, i.e. whose period ENDS on or after it."
        },
        overlapping_until: {
          type: "string",
          description: "ISO 8601 date (YYYY-MM-DD). Only statements whose period overlaps this date or earlier, i.e. whose period STARTS on or before it."
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

    # Visibility is filtered in SQL, not after the fact. Post-filtering a page
    # would both underfill it and — because there is no cursor — make a statement
    # permanently unreachable whenever enough newer rows the caller cannot see sit
    # in front of it. Mirrors AccountStatement#viewable_by? for a statement
    # manager: unlinked statements are visible, linked ones follow the account.
    scope = family.account_statements
      .where(account_id: nil)
      .or(family.account_statements.where(account_id: user.accessible_accounts.select(:id)))
      .includes(:account, :suggested_account)
      .ordered

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

    # Downcased because the column is constrained to lowercase hex
    # (chk_account_statements_content_sha256), so uppercase input would not merely
    # be unlikely to match — it could never match, and the agent would read the
    # empty result as "not archived" and upload a duplicate.
    if params["content_sha256"].present?
      scope = scope.where(content_sha256: params["content_sha256"].to_s.strip.downcase)
    end

    if params["overlapping_from"].present?
      date = parse_date(params["overlapping_from"])
      return error("invalid_date", "overlapping_from must be an ISO 8601 date (YYYY-MM-DD).") unless date

      scope = scope.where("period_end_on >= ?", date)
    end

    if params["overlapping_until"].present?
      date = parse_date(params["overlapping_until"])
      return error("invalid_date", "overlapping_until must be an ISO 8601 date (YYYY-MM-DD).") unless date

      scope = scope.where("period_start_on <= ?", date)
    end

    limit = (params["limit"] || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
    # Over-fetch by one to report has_more without a second count query. The rows
    # are already visibility-scoped, so the page is never underfilled and the
    # count discloses nothing the caller cannot see.
    rows = scope.limit(limit + 1).to_a
    statements = rows.first(limit)

    {
      success: true,
      returned: statements.size,
      has_more: rows.size > limit,
      statements: statements.map { |statement| statement_payload(statement) }
    }
  end
end
