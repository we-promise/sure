# frozen_string_literal: true

class Assistant::Function::UpdateTransfer < Assistant::Function
  include Assistant::Function::TransferSupport

  TRUTHY_INPUTS = [ true, "true", "t", "1", 1 ].freeze
  FALSY_INPUTS = [ false, "false", "f", "0", 0 ].freeze

  class << self
    def name = "update_transfer"

    def description
      <<~INSTRUCTIONS
        Updates a transfer between two writable accounts. Pass exactly one
        selector: id or transfer_id from get_transfers, or transaction_id from
        get_transactions.

        amount, date, notes, and exchange_rate edit the transfer itself.
        investment_contribution switches a confirmed transfer into an Investment
        or Crypto account between spending and a plain transfer. dry_run is
        supported for that switch only.
      INSTRUCTIONS
    end
  end

  def strict_mode? = false

  def params_schema
    build_schema(
      properties: {
        id: { type: "string", description: "Transfer ID from get_transfers; alias of transfer_id" },
        transfer_id: { type: "string", description: "Transfer ID from get_transfers" },
        transaction_id: { type: "string", description: "ID of either transaction in the transfer, from get_transactions" },
        amount: { type: "number", exclusiveMinimum: 0, description: "New positive source amount" },
        date: { type: "string", format: "date", description: "New YYYY-MM-DD date" },
        notes: { type: [ "string", "null" ], description: "New notes, or null to clear" },
        exchange_rate: { type: "number", exclusiveMinimum: 0, description: "Optional custom exchange rate for a new amount" },
        investment_contribution: { type: "boolean", description: "true counts the transfer as spending; false makes it a plain transfer" },
        dry_run: { type: "boolean", description: "Preview an investment_contribution switch without changing it" }
      }
    )
  end

  def call(params = {})
    changed_fields = params.keys & %w[amount date notes exchange_rate investment_contribution]
    return error("invalid_arguments", "Provide at least one field to update.") if changed_fields.empty?

    transfer = lookup_requested_transfer(params)
    return transfer if transfer.is_a?(Hash)

    requested_amount = positive_decimal(params["amount"], "amount") if params.key?("amount")
    requested_date = Date.iso8601(params["date"].to_s) if params.key?("date")
    requested_rate = positive_decimal(params["exchange_rate"], "exchange_rate") if params.key?("exchange_rate")
    financial_change = changed_fields.intersect?(%w[amount date exchange_rate])

    enabled = parse_boolean(params["investment_contribution"]) if params.key?("investment_contribution")
    if params.key?("investment_contribution") && enabled.nil?
      return error("invalid_arguments", "Pass investment_contribution: true or false.")
    end
    if params.key?("investment_contribution") && !transfer.investment_contribution_switchable?
      return error("not_switchable", "Only a confirmed transfer from a cash account into an investment or crypto account can be switched between an investment contribution and a plain transfer.")
    end

    dry_run = parse_boolean(params["dry_run"]) if params.key?("dry_run")
    return error("invalid_arguments", "Pass dry_run: true or false.") if params.key?("dry_run") && dry_run.nil?

    if dry_run
      return error("invalid_arguments", "dry_run is supported only for investment_contribution.") unless changed_fields == [ "investment_contribution" ]

      return {
        success: true,
        dry_run: true,
        transfer: serialize_transfer(transfer),
        message: "Would make #{transfer.name} #{describe(enabled)}."
      }
    end

    switch_failed = false
    updated = Transfer.uncached do
      Transfer.transaction do
        current = scoped_transfers.find_by(id: transfer.id)
        next nil unless current

        accounts = [ current.from_account, current.to_account ].compact
        Account::MutationAccess.lock!(accounts:, user:, level: Account::MutationAccess::WRITE)
        locked = scoped_transfers.lock.find_by(id: transfer.id)
        next nil unless locked
        locked.lock!

        if financial_change
          principal_entries = [ locked.outflow_transaction.entry, locked.inflow_transaction.entry ]
          fee_entries = params.key?("date") ? locked.fee_transactions.includes(:entry).map(&:entry) : []
          (principal_entries + fee_entries).compact.uniq.sort_by(&:id).each(&:lock!)

          outflow_entry, inflow_entry = principal_entries
          original_amount = outflow_entry.amount.abs
          amount = requested_amount || original_amount
          date = requested_date || locked.date
          converted = converted_amount(locked, amount, original_amount, date, requested_rate)

          outflow_entry.update!(amount:, date:)
          inflow_entry.update!(amount: -converted, date:)
          mark_financial_edit!(outflow_entry)
          mark_financial_edit!(inflow_entry)

          fee_entries.each do |entry|
            entry.update!(date:)
            mark_financial_edit!(entry)
          end

          locked.amount = amount
        end

        locked.notes = params["notes"] if params.key?("notes")
        locked.save! if locked.changed?
        if params.key?("investment_contribution") && !locked.update_investment_contribution!(enabled)
          switch_failed = true
          raise ActiveRecord::Rollback
        end

        locked
      end
    end
    return error("not_updated", "Could not update the transfer; it may have changed. Reload and try again.") if switch_failed
    return error("not_found", "The transfer was unlinked, or you can no longer write to its accounts.") unless updated

    updated.sync_account_later if financial_change
    updated.reload
    {
      success: true,
      transfer: serialize_transfer(updated),
      message: params.key?("investment_contribution") ? "#{updated.name} is now #{describe(enabled)}." : "Transfer updated."
    }
  rescue Account::MutationAccess::Denied
    error("not_found", "Writable transfer not found.")
  rescue Date::Error, ArgumentError, Money::ConversionError => e
    error("invalid_parameters", e.message)
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def lookup_requested_transfer(params)
      selectors = %w[id transfer_id transaction_id].select { |key| params[key].present? }
      return error("invalid_arguments", "Pass exactly one of id, transfer_id, or transaction_id.") unless selectors.one?

      selector = selectors.first
      transfer = if selector == "transaction_id"
        find_transfer_for_transaction(params[selector])
      else
        find_transfer(params[selector])
      end
      transfer || not_found(params[selector])
    end

    def not_found(reference)
      error("not_found", "No transfer for '#{reference}' between accounts you can write to.")
    end

    def parse_boolean(value)
      normalized = value.is_a?(String) ? value.strip.downcase : value
      return true if TRUTHY_INPUTS.include?(normalized)
      false if FALSY_INPUTS.include?(normalized)
    end

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

    def describe(enabled)
      enabled ? "an investment contribution (counted as spending)" : "a plain transfer (not counted as spending)"
    end

    def serialize_transfer(transfer)
      outflow = transfer.outflow_transaction.reload
      {
        id: transfer.id,
        name: transfer.name,
        status: transfer.status,
        amount: transfer.amount,
        date: transfer.date,
        notes: transfer.notes,
        investment_contribution: transfer.investment_contribution?,
        outflow: {
          id: outflow.id,
          account: outflow.entry.account.name,
          kind: outflow.kind,
          category: outflow.category&.name
        },
        inflow: {
          id: transfer.inflow_transaction.id,
          account: transfer.inflow_transaction.entry.account.name
        }
      }
    end
end
