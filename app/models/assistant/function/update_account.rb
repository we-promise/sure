class Assistant::Function::UpdateAccount < Assistant::Function
  class << self
    def name = "update_account"

    def description
      "Updates a writable Sure account. Use get_accounts first to find an id with writable=true."
    end
  end

  def strict_mode? = false

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: { type: "string", description: "Account ID from get_accounts" },
        name: { type: "string", description: "New account name" },
        balance: { type: "number", description: "New current balance in major currency units" },
        currency: { type: "string", description: "New ISO 4217 currency code" },
        notes: { type: [ "string", "null" ], description: "New notes, or null to clear" },
        exclude_from_reports: { type: "boolean", description: "Whether to exclude the account from reports" }
      }
    )
  end

  def call(params = {})
    account = find_account(params["id"])
    return error("not_found", "Writable account not found.") unless account

    changed_fields = params.keys & %w[name balance currency notes exclude_from_reports]
    return error("no_changes", "Provide at least one field to update.") if changed_fields.empty?

    Account.transaction do
      account.lock!

      if params.key?("balance")
        balance = BigDecimal(params["balance"].to_s)
        result = account.set_current_balance(balance)
        return error("balance_update_failed", result.error_message) unless result.success?
      end

      attrs = {}
      attrs[:name] = params["name"].to_s.strip if params.key?("name")
      attrs[:currency] = params["currency"].to_s.upcase if params.key?("currency")
      attrs[:notes] = params["notes"] if params.key?("notes")
      attrs[:exclude_from_reports] = params["exclude_from_reports"] if params.key?("exclude_from_reports")
      account.update!(attrs) if attrs.any?
      account.lock_saved_attributes!
    end

    account.reload
    {
      success: true,
      account: {
        id: account.id, name: account.name, balance: account.balance,
        currency: account.currency, notes: account.notes,
        exclude_from_reports: account.exclude_from_reports
      },
      message: "Account '#{account.name}' updated."
    }
  rescue ArgumentError
    error("invalid_balance", "balance must be a finite number.")
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def find_account(id)
      return nil unless valid_uuid?(id)

      family.accounts.writable_by(user).visible.find_by(id: id)
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
