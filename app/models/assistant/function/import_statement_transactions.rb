require "csv"
require "bigdecimal"

# Batch endpoint for subscription-backed Codex/MCP imports. Codex can read a PDF
# in its client, then call this tool with the extracted rows; Sure never needs an
# OpenAI API key for the extraction step and still leaves the rows in the normal
# review flow before they reach the ledger.
class Assistant::Function::ImportStatementTransactions < Assistant::Function
  MAX_TRANSACTIONS = 2_000

  class << self
    def name
      "import_statement_transactions"
    end

    def description
      <<~INSTRUCTIONS
        Create a reviewable transaction import from transactions you extracted
        from a PDF statement. Use this after reading a PDF with Codex or another
        subscription-backed assistant when the Sure API-key PDF processor is not
        available. Do not publish the import; the user must review and publish it.

        Amounts use Sure's statement convention: positive inflows and negative
        outflows. Include the account_id returned by get_accounts.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[account_id transactions],
      properties: {
        account_id: { type: "string", description: "Writable account UUID from get_accounts." },
        filename: { type: "string", description: "Original PDF filename, if known." },
        transactions: {
          type: "array",
          description: "Rows extracted from the statement.",
          items: {
            type: "object",
            additionalProperties: false,
            properties: {
              date: { type: "string", description: "ISO date (YYYY-MM-DD)." },
              amount: { type: [ "number", "string" ], description: "Signed amount: positive inflow, negative outflow." },
              name: { type: "string" },
              merchant: { type: [ "string", "null" ], description: "Optional merchant, payer, or payee name." },
              category: { type: [ "string", "null" ] },
              notes: { type: [ "string", "null" ] }
            },
            required: %w[date amount name]
          }
        }
      }
    )
  end

  def call(params = {})
    return failure("forbidden", "Statement imports require an admin or member role.") unless AccountStatement.statement_manager?(user)

    account = family.accounts.writable_by(user).find_by(id: params["account_id"])
    return failure("account_not_found", "No writable account matched account_id.") unless account

    transactions = Array(params["transactions"])
    return failure("transactions_required", "Provide at least one extracted transaction.") if transactions.empty?
    return failure("too_many_transactions", "A single statement import may contain at most #{MAX_TRANSACTIONS} transactions.") if transactions.size > MAX_TRANSACTIONS

    rows = transactions.map.with_index do |transaction, index|
      normalize_transaction(transaction, index)
    end

    import = family.imports.create!(
      type: "TransactionImport",
      account: account,
      raw_file_str: CSV.generate { |csv| csv << %w[date amount name merchant category notes]; rows.each { |row| csv << row } },
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      category_col_label: "category",
      notes_col_label: "notes",
      date_format: "%Y-%m-%d",
      signage_convention: "inflows_positive"
    )
    import.generate_rows_from_csv
    import.sync_mappings

    {
      success: true,
      import_id: import.id,
      transaction_count: import.rows_count,
      filename: params["filename"].to_s.presence,
      message: "Created a reviewable transaction import. Review and publish it before changing the ledger."
    }.compact
  rescue ArgumentError, Date::Error => e
    failure("invalid_transaction", e.message)
  rescue ActiveRecord::RecordInvalid => e
    failure("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private

    def normalize_transaction(transaction, index)
      raise ArgumentError, "Transaction #{index + 1} must be an object." unless transaction.is_a?(Hash)

      date = Date.iso8601(transaction["date"].to_s).iso8601
      name = transaction["name"].to_s.strip
      raise ArgumentError, "Transaction #{index + 1} is missing a name." if name.blank?

      amount = begin
        BigDecimal(transaction["amount"].to_s).to_s("F")
      rescue ArgumentError
        raise ArgumentError, "Transaction #{index + 1} has an invalid amount."
      end
      [ date, amount, name, transaction["merchant"].to_s, transaction["category"].to_s, transaction["notes"].to_s ]
    end

    def failure(error, message)
      { success: false, error: error, message: message }
    end
end
