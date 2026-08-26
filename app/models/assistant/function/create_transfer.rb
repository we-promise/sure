require "digest"

class Assistant::Function::CreateTransfer < Assistant::Function
  class << self
    def name = "create_transfer"

    def description
      "Creates an idempotent confirmed transfer between two writable accounts. Use get_accounts first."
    end
  end

  def strict_mode? = false

  def params_schema
    build_schema(
      required: %w[from_account_id to_account_id amount date external_id],
      properties: {
        from_account_id: { type: "string", description: "Writable source account id from get_accounts" },
        to_account_id: { type: "string", description: "Writable destination account id from get_accounts" },
        amount: { type: "number", exclusiveMinimum: 0, description: "Positive source amount" },
        date: { type: "string", format: "date", description: "Transfer date in YYYY-MM-DD format" },
        external_id: { type: "string", minLength: 1, maxLength: 255, description: "Stable caller-generated idempotency key" },
        exchange_rate: { type: "number", exclusiveMinimum: 0, description: "Optional custom exchange rate" },
        source_fee_amount: { type: "number", minimum: 0 },
        destination_fee_amount: { type: "number", minimum: 0 }
      }
    )
  end

  def call(params = {})
    accounts = family.accounts.writable_by(user).visible.where(id: [ params["from_account_id"], params["to_account_id"] ]).index_by { |account| account.id.to_s }
    source = accounts[params["from_account_id"].to_s]
    destination = accounts[params["to_account_id"].to_s]
    return error("account_not_found", "Both source and destination accounts must be writable.") unless source && destination
    return error("same_account", "Source and destination accounts must be different.") if source == destination

    external_id = params["external_id"].to_s.strip
    return error("invalid_external_id", "external_id is required and must be at most 255 characters.") if external_id.blank? || external_id.length > 255
    storage_key = "#{family.id}:#{external_id}"

    date = Date.iso8601(params["date"].to_s)
    amount = positive_decimal(params["amount"], "amount")
    exchange_rate = optional_positive_decimal(params["exchange_rate"], "exchange_rate")
    source_fee = non_negative_decimal(params["source_fee_amount"], "source_fee_amount")
    destination_fee = non_negative_decimal(params["destination_fee_amount"], "destination_fee_amount")
    fingerprint = fingerprint_for(source, destination, amount, date, exchange_rate, source_fee, destination_fee)

    existing = Transfer.find_by(external_id: storage_key)
    return idempotency_result(existing, fingerprint) if existing

    transfer = Transfer.transaction do
      created = Transfer::Creator.new(
        family: family,
        source_account_id: source.id,
        destination_account_id: destination.id,
        date: date,
        amount: amount,
        exchange_rate: exchange_rate,
        source_fee_amount: source_fee,
        destination_fee_amount: destination_fee
      ).create(sync: false)
      created.update!(external_id: storage_key, idempotency_fingerprint: fingerprint)
      created
    end

    sync_transfer_accounts(transfer)
    { success: true, created: true, transfer: serialize(transfer), message: "Transfer created." }
  rescue ActiveRecord::RecordNotUnique
    existing = Transfer.find_by(external_id: storage_key)
    return idempotency_result(existing, fingerprint) if existing

    raise
  rescue Date::Error, ArgumentError, Money::ConversionError => e
    error("invalid_parameters", e.message)
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def fingerprint_for(source, destination, amount, date, exchange_rate, source_fee, destination_fee)
      payload = {
        from_account_id: source.id.to_s,
        to_account_id: destination.id.to_s,
        amount: amount.to_s("F"),
        date: date.iso8601,
        exchange_rate: exchange_rate&.to_s("F"),
        source_fee_amount: source_fee.to_s("F"),
        destination_fee_amount: destination_fee.to_s("F")
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def idempotency_result(transfer, fingerprint)
      unless transfer&.idempotency_fingerprint == fingerprint
        return error("idempotency_conflict", "external_id was already used with different transfer parameters.")
      end

      sync_transfer_accounts(transfer)
      { success: true, created: false, transfer: serialize(transfer), message: "Transfer already existed." }
    end

    def sync_transfer_accounts(transfer)
      [ transfer.from_account, transfer.to_account ].compact.uniq.sort_by(&:id).each(&:sync_later)
    end

    def positive_decimal(value, name)
      amount = BigDecimal(value.to_s)
      raise ArgumentError, "#{name} must be finite and greater than 0" unless amount.finite? && amount.positive?

      amount
    end

    def optional_positive_decimal(value, name)
      return nil if value.nil?

      positive_decimal(value, name)
    end

    def non_negative_decimal(value, name)
      return 0.to_d if value.nil?

      amount = BigDecimal(value.to_s)
      raise ArgumentError, "#{name} must be finite and non-negative" unless amount.finite? && amount >= 0

      amount
    end

    def serialize(transfer)
      {
        id: transfer.id,
        external_id: transfer.external_id.to_s.split(":", 2).last,
        status: transfer.status,
        date: transfer.date,
        amount: transfer.outflow_transaction.entry.amount.abs,
        from_account_id: transfer.from_account.id,
        to_account_id: transfer.to_account.id,
        from_currency: transfer.from_account.currency,
        to_currency: transfer.to_account.currency
      }
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
