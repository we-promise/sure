class Assistant::Function::CreateAccount < Assistant::Function
  class << self
    def name = "create_account"

    def description
      "Creates a manual Sure account and returns the account id for transaction and transfer tools."
    end
  end

  def strict_mode? = false

  def params_schema
    build_schema(
      required: %w[name account_type balance currency],
      properties: {
        name: { type: "string", description: "Account name" },
        account_type: { type: "string", enum: Accountable::TYPES, description: "Sure account type" },
        subtype: { type: "string", description: "Optional subtype supported by the account type" },
        balance: { type: "number", description: "Current account balance in major currency units" },
        currency: { type: "string", description: "ISO 4217 currency code" },
        opening_balance_date: { type: "string", format: "date", description: "Opening balance date in YYYY-MM-DD format" },
        notes: { type: "string", description: "Optional account notes" },
        exclude_from_reports: { type: "boolean", description: "Exclude this account from financial reports" }
      }
    )
  end

  def call(params = {})
    accountable_class = Accountable.from_type(params["account_type"])
    return error("invalid_account_type", "account_type must be one of: #{Accountable::TYPES.join(", ")}.") unless accountable_class

    subtype = params["subtype"].presence
    if subtype && (!accountable_class.const_defined?(:SUBTYPES) || !accountable_class::SUBTYPES.key?(subtype))
      return error("invalid_subtype", "subtype is not valid for #{accountable_class.name}.")
    end

    opening_balance_date = params["opening_balance_date"].present? ? Date.iso8601(params["opening_balance_date"].to_s) : Date.current
    accountable = accountable_class.new
    accountable.subtype = subtype if subtype && accountable.respond_to?(:subtype=)

    account = Account.transaction do
      created = family.accounts.create_and_sync(
        {
          name: params["name"].to_s.strip,
          balance: BigDecimal(params["balance"].to_s),
          currency: params["currency"].to_s.upcase,
          notes: params["notes"],
          exclude_from_reports: params.fetch("exclude_from_reports", false),
          accountable: accountable,
          owner: user
        },
        opening_balance_date: opening_balance_date
      )
      created.lock_saved_attributes!
      created
    end

    { success: true, account: serialize(account), message: "Account '#{account.name}' created." }
  rescue Date::Error, ArgumentError => e
    error("invalid_parameters", e.message)
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def serialize(account)
      {
        id: account.id,
        name: account.name,
        account_type: account.accountable_type,
        subtype: account.subtype,
        balance: account.balance,
        currency: account.currency,
        status: account.status
      }
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
