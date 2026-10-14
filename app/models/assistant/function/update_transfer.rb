# frozen_string_literal: true

# UpdateTransfer — changes how a confirmed transfer counts, as the transfer
# drawer does. Today that is one switch: whether a transfer from a cash account
# into an investment or crypto account is an investment contribution (counted
# as spending in budgets and reports, the default) or a plain transfer (e.g.
# a brokerage or crypto account used only to convert currency). See
# Transfer#update_investment_contribution!, which locks the choice against
# provider syncs.
class Assistant::Function::UpdateTransfer < Assistant::Function
  include Assistant::Function::TransferSupport

  class << self
    def name
      "update_transfer"
    end

    def description
      <<~INSTRUCTIONS
        Changes how a confirmed transfer between two of the user's accounts
        counts in budgets and reports.

        investment_contribution: a transfer from a cash account into an
        investment or crypto account counts as spending by default (an
        investment contribution). Pass false to make it a plain transfer that
        budgets and reports ignore, e.g. when the brokerage or crypto account is
        only used to convert money into another currency; pass true to count it
        as spending again. The choice survives
        account syncs. Other transfers have no such switch.

        Pass the id of either transaction in the transfer (get_transactions
        marks them is_transfer), or the transfer_id. Both accounts must be
        writable. Pass dry_run: true to see the effect first.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      properties: {
        transaction_id: {
          type: "string",
          description: "ID of either transaction in the transfer, from get_transactions. Omit when passing transfer_id."
        },
        transfer_id: {
          type: "string",
          description: "Transfer ID. Omit when passing transaction_id."
        },
        investment_contribution: {
          type: "boolean",
          description: "true counts a transfer into an investment or crypto account as spending; false makes it a plain transfer."
        },
        dry_run: {
          type: "boolean",
          description: "Describe the change without making it. Defaults to false."
        }
      }
    )
  end

  def call(params = {})
    enabled = parse_boolean(params["investment_contribution"])
    return error("invalid_arguments", "Pass investment_contribution: true or false.") if enabled.nil?

    transfer = lookup_transfer(params)
    return transfer if transfer.is_a?(Hash)

    unless transfer.investment_contribution_switchable?
      return error("not_switchable", "Only a confirmed transfer from a cash account into an investment or crypto account can be switched between an investment contribution and a plain transfer.")
    end

    if ActiveModel::Type::Boolean.new.cast(params["dry_run"])
      return {
        success: true,
        dry_run: true,
        transfer: serialize_transfer(transfer),
        message: "Would make #{transfer.name} #{describe(enabled)}."
      }
    end

    # Lock, then re-find within the writable scope, so write access lost since
    # the lookup is caught.
    updated = Transfer.uncached do
      Transfer.transaction do
        locked = scoped_transfers.lock.find_by(id: transfer.id)
        next nil unless locked

        locked.update_investment_contribution!(enabled) ? locked : nil
      end
    end
    return error("not_found", "The transfer was unlinked, or you can no longer write to its accounts.") unless updated

    { success: true, transfer: serialize_transfer(updated), message: "#{updated.name} is now #{describe(enabled)}." }
  end

  private
    # The tool caller does not enforce params_schema, and
    # ActiveModel::Type::Boolean reads every unrecognized string (e.g. "no")
    # as true, which would turn on the contribution the caller meant to turn off.
    TRUTHY_INPUTS = [ true, "true", "t", "1", 1 ].freeze
    FALSY_INPUTS = [ false, "false", "f", "0", 0 ].freeze

    def parse_boolean(value)
      normalized = value.is_a?(String) ? value.strip.downcase : value
      return true if TRUTHY_INPUTS.include?(normalized)
      false if FALSY_INPUTS.include?(normalized)
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
