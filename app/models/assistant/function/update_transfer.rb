class Assistant::Function::UpdateTransfer < Assistant::Function
  class << self
    def name = "update_transfer"
    def description = "Updates amount, date, or notes for a transfer whose two accounts are writable."
  end

  def strict_mode? = false

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: { type: "string", description: "Transfer id from get_transfers" },
        amount: { type: "number", exclusiveMinimum: 0, description: "New positive source amount" },
        date: { type: "string", format: "date", description: "New YYYY-MM-DD date" },
        notes: { type: [ "string", "null" ], description: "New notes, or null to clear" },
        exchange_rate: { type: "number", exclusiveMinimum: 0, description: "Optional custom exchange rate for a new amount" }
      }
    )
  end

  def call(params = {})
    transfer = find_writable_transfer(params["id"])
    return error("not_found", "Writable transfer not found.") unless transfer
    return error("no_changes", "Provide amount, date, notes, or exchange_rate.") if (params.keys & %w[amount date notes exchange_rate]).empty?

    entry_change = params.key?("amount") || params.key?("date") || params.key?("exchange_rate")

    Transfer.transaction do
      transfer.lock!
      [ transfer.outflow_transaction.entry, transfer.inflow_transaction.entry ].sort_by(&:id).each(&:lock!) if entry_change

      attrs = {}
      if entry_change
        outflow_entry = transfer.outflow_transaction.entry
        inflow_entry = transfer.inflow_transaction.entry
        original_amount = outflow_entry.amount.abs
        amount = params.key?("amount") ? BigDecimal(params["amount"].to_s) : original_amount
        return error("invalid_amount", "amount must be greater than 0.") unless amount.positive? && amount.finite?

        date = params.key?("date") ? Date.iso8601(params["date"].to_s) : transfer.date
        converted = converted_amount(transfer, amount, original_amount, date, params)
        outflow_entry.update!(amount: amount, date: date)
        inflow_entry.update!(amount: -converted, date: date)
        outflow_entry.lock_saved_attributes!
        inflow_entry.lock_saved_attributes!
        attrs[:amount] = amount
      end

      attrs[:notes] = params["notes"] if params.key?("notes")
      transfer.update!(attrs)
    end
    transfer.sync_account_later if entry_change

    transfer.reload
    { success: true, transfer: { id: transfer.id, amount: transfer.amount, date: transfer.date, notes: transfer.notes }, message: "Transfer updated." }
  rescue Date::Error, ArgumentError, Money::ConversionError => e
    error("invalid_parameters", e.message)
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def converted_amount(transfer, amount, original_amount, date, params)
      return amount if transfer.from_account.currency == transfer.to_account.currency

      if params.key?("exchange_rate")
        return Money.new(amount, transfer.from_account.currency)
          .exchange_to(transfer.to_account.currency, date: date, custom_rate: params["exchange_rate"]).amount
      end

      original_destination_amount = transfer.inflow_transaction.entry.amount.abs
      params.key?("amount") ? original_destination_amount * amount / original_amount : original_destination_amount
    end

    def find_writable_transfer(id)
      return nil unless valid_uuid?(id)

      transaction_ids = family.transactions
        .joins(:entry)
        .where(entries: { account_id: family.accounts.writable_by(user).visible.select(:id) })
        .select(:id)
      Transfer.where(inflow_transaction_id: transaction_ids, outflow_transaction_id: transaction_ids).find_by(id: id)
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
