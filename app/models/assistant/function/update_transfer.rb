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
    transfer = find_family_transfer(params["id"])
    return error("not_found", "Writable transfer not found.") unless transfer

    changed_fields = params.keys & %w[amount date notes exchange_rate]
    return error("no_changes", "Provide amount, date, notes, or exchange_rate.") if changed_fields.empty?

    requested_amount = positive_decimal(params["amount"], "amount") if params.key?("amount")
    requested_date = Date.iso8601(params["date"].to_s) if params.key?("date")
    requested_rate = positive_decimal(params["exchange_rate"], "exchange_rate") if params.key?("exchange_rate")
    financial_change = changed_fields.intersect?(%w[amount date exchange_rate])

    Transfer.transaction do
      accounts = [ transfer.from_account, transfer.to_account ].compact
      Account::MutationAccess.lock!(accounts:, user:, level: Account::MutationAccess::WRITE)
      transfer.lock!

      if financial_change
        principal_entries = [ transfer.outflow_transaction.entry, transfer.inflow_transaction.entry ]
        fee_entries = params.key?("date") ? transfer.fee_transactions.includes(:entry).map(&:entry) : []
        (principal_entries + fee_entries).compact.uniq.sort_by(&:id).each(&:lock!)

        outflow_entry, inflow_entry = principal_entries
        original_amount = outflow_entry.amount.abs
        amount = requested_amount || original_amount
        date = requested_date || transfer.date
        converted = converted_amount(transfer, amount, original_amount, date, requested_rate)

        outflow_entry.update!(amount:, date:)
        inflow_entry.update!(amount: -converted, date:)
        mark_financial_edit!(outflow_entry)
        mark_financial_edit!(inflow_entry)

        fee_entries.each do |entry|
          entry.update!(date:)
          mark_financial_edit!(entry)
        end

        transfer.amount = amount
      end

      transfer.notes = params["notes"] if params.key?("notes")
      transfer.save! if transfer.changed?
    end

    transfer.sync_account_later if financial_change
    transfer.reload
    {
      success: true,
      transfer: { id: transfer.id, amount: transfer.amount, date: transfer.date, notes: transfer.notes },
      message: "Transfer updated."
    }
  rescue Account::MutationAccess::Denied
    error("not_found", "Writable transfer not found.")
  rescue Date::Error, ArgumentError, Money::ConversionError => e
    error("invalid_parameters", e.message)
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def converted_amount(transfer, amount, original_amount, date, exchange_rate)
      return amount if transfer.from_account.currency == transfer.to_account.currency

      if exchange_rate
        return Money.new(amount, transfer.from_account.currency)
          .exchange_to(transfer.to_account.currency, date:, custom_rate: exchange_rate).amount
      end

      original_destination_amount = transfer.inflow_transaction.entry.amount.abs
      amount == original_amount ? original_destination_amount : original_destination_amount * amount / original_amount
    end

    def positive_decimal(value, name)
      amount = BigDecimal(value.to_s)
      raise ArgumentError, "#{name} must be a finite number greater than 0." unless amount.finite? && amount.positive?

      amount
    end

    def mark_financial_edit!(entry)
      entry.lock_saved_attributes!
      entry.mark_user_modified!
    end

    def find_family_transfer(id)
      return nil unless valid_uuid?(id)

      Transfer.for_family(family)
        .between_accounts(family.accounts.writable_by(user).visible.select(:id))
        .find_by(id:)
    end

    def error(key, message)
      { success: false, error: key, message: }
    end
end
