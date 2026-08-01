# frozen_string_literal: true

class Assistant::Function::RecordValuation < Assistant::Function
  class << self
    def name
      "record_valuation"
    end

    def description
      <<~INSTRUCTIONS
        Record the value of an account on a given date, with a citation for where
        the number came from.

        Use this for holdings the app cannot value on its own — property,
        off-bank positions, private company stakes, collectibles — and to correct
        a manual account's balance from a primary-source document.

        The `source` citation is required and is checked against this grammar:

            ["estimated: "] citation [" (grade: A|B|C)"]

        - `estimated: ` prefix — the value was interpolated or proxied, not read
          off a document. Estimates must carry a grade.
        - grade `A` — an official document for that exact date (statement, filed
          return, capital account); `B` — derived with a document; `C` — a proxy
          or assumption, i.e. a standing TODO to re-derive from the real source.

        Examples of valid citations:

            "Private bank statement 2026-03-31, securities subtotal (grade: A)"
            "estimated: linear interpolation over 2024-08 / 2024-12 anchors (grade: C)"

        If you do not have a document to cite, do not invent one and do not call
        this function — ask the user for the source. A value with no provenance
        is worse than a missing value, because it looks authoritative.

        Recording a valuation on a date that already has one replaces it. The
        citation is stored in the entry's notes; any note a person wrote there is
        preserved and the new citation appended below it.

        Example:

        ```
        record_valuation({
          account_id: "abc123-def456",
          date: "2026-03-31",
          amount: 412500.00,
          source: "Appraisal report 2026-03-12 by {firm} (grade: A)"
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
      required: %w[account_id date amount source],
      properties: {
        account_id: {
          type: "string",
          description: "UUID of the account to value. The user must have write access to it."
        },
        date: {
          type: "string",
          description: "ISO 8601 date (YYYY-MM-DD) the value applies to. For a period-end value, use the last day of the period."
        },
        amount: {
          type: "number",
          description: "The account's value on that date, in the account's own currency."
        },
        source: {
          type: "string",
          description: "Required citation naming the document this value came from, in the grammar: [\"estimated: \"] citation [\" (grade: A|B|C)\"]."
        }
      }
    )
  end

  def call(params = {})
    citation = Provenance::Citation.parse!(params["source"])

    date = parse_date(params["date"])
    return error("invalid_date", "date must be an ISO 8601 date (YYYY-MM-DD).") unless date

    amount = parse_decimal(params["amount"])
    return error("invalid_amount", "amount must be a number.") if amount.nil?

    account_id = params["account_id"].to_s
    return error("invalid_account_id", "account_id must be a UUID.") unless valid_uuid?(account_id)

    # Unlike the Statement Vault tools, this one deliberately does NOT check
    # AccountStatement.statement_manager?. That role governs the document archive;
    # writing a value to an account is governed by the account ACL, and
    # writable_by is the same scope the human-facing api/v1/valuations endpoint
    # uses. Do not "tighten" this by adding the vault role — the two permissions
    # answer different questions.
    account = family.accounts.writable_by(user).find_by(id: account_id)
    return error("account_not_found", "No account found with that ID that this user can write to.") unless account

    entry = nil
    replaced_existing = false
    failure_message = nil

    ActiveRecord::Base.transaction do
      account.lock!
      replaced_existing = account.entries.valuations.exists?(date: date)

      result = account.create_reconciliation(balance: amount, date: date)

      unless result.success?
        failure_message = result.error_message
        raise ActiveRecord::Rollback
      end

      entry = account.entries.valuations.find_by!(date: date)
      entry.update!(notes: merged_notes(entry.notes, citation))
    end

    unless entry
      return error("valuation_failed", failure_message.presence || "The valuation could not be recorded.")
    end

    {
      success: true,
      entry_id: entry.id,
      account: { id: account.id, name: account.name, currency: account.currency },
      date: date.iso8601,
      amount: entry.amount.to_s,
      amount_formatted: entry.amount_money.format,
      replaced_existing: replaced_existing,
      provenance: citation.to_h,
      message: "Recorded #{entry.amount_money.format} for #{account.name} on #{date.iso8601}, cited as: #{citation}."
    }
  rescue Provenance::Citation::InvalidError => e
    error(
      "invalid_source_citation",
      "#{e.message}. Every recorded value must cite its source, in the grammar: #{Provenance::Citation.grammar}."
    )
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    # Re-recording a date replaces the valuation, and the citation lives in the
    # entry's notes — where a human may also have written something. Nothing is
    # ever removed: the note is kept and the citation appended, because we cannot
    # tell a tool-written line from a human one (almost any prose is a valid
    # ungraded citation) and guessing wrong would destroy the only copy.
    #
    # Re-recording with the same citation is a no-op, so the common case does not
    # grow the note. A genuinely different citation is appended, which is the
    # right outcome for a provenance trail: it records that the cited basis for
    # this date changed.
    def merged_notes(existing, citation)
      existing = existing.to_s.strip
      return citation.to_s if existing.blank?
      return existing if existing.lines.any? { |line| line.strip == citation.to_s }

      [ existing, citation.to_s ].join("\n\n")
    end

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    def parse_decimal(value)
      return nil if value.nil? || value.to_s.strip.empty?

      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def error(key, message, extras = {})
      { success: false, error: key, message: message }.merge(extras)
    end
end
