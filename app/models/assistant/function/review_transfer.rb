# frozen_string_literal: true

# ReviewTransfer — confirms or rejects a pending auto-matched transfer, the
# same as the Confirm / Reject buttons on an "Auto-matched" transaction.
# Rejecting records the pairing so auto-match does not suggest it again.
class Assistant::Function::ReviewTransfer < Assistant::Function
  include Assistant::Function::TransferMatchSupport

  ACTIONS = %w[confirm reject].freeze

  class << self
    def name
      "review_transfer"
    end

    def description
      <<~INSTRUCTIONS
        Confirms or rejects a transfer that Sure auto-matched and the user has
        not reviewed yet (status "pending" in get_transfer_match_candidates).

        confirm keeps the match. reject unlinks the two transactions and stops
        auto-match from suggesting that pairing again.

        Only pending transfers can be reviewed. Both accounts must be writable.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[transfer_id action],
      properties: {
        transfer_id: {
          type: "string",
          description: "Transfer ID from get_transfer_match_candidates."
        },
        action: {
          type: "string",
          enum: ACTIONS,
          description: "confirm or reject."
        }
      }
    )
  end

  def call(params = {})
    return error("invalid_arguments", "action must be one of: #{ACTIONS.join(", ")}.") unless ACTIONS.include?(params["action"])

    transfer = find_transfer(params["transfer_id"])
    return error("not_found", "No transfer with id '#{params["transfer_id"]}' between accounts you can write to.") unless transfer
    return error("not_pending", "Only pending auto-matched transfers can be reviewed; this one is #{transfer.status}.") unless transfer.pending?

    snapshot = {
      transfer_id: transfer.id,
      outflow: serialize_transaction(transfer.outflow_transaction),
      inflow: serialize_transaction(transfer.inflow_transaction)
    }

    # Lock and recheck, so of two concurrent reviews only the first one acts:
    # otherwise a reject could destroy a transfer another call just confirmed.
    reviewed = transfer.with_lock do
      next false unless transfer.pending?

      params["action"] == "confirm" ? transfer.confirm! : transfer.reject!
      true
    end
    return error("not_pending", "The transfer was reviewed by another request; it is no longer pending.") unless reviewed

    if params["action"] == "confirm"
      { success: true, action: "confirmed", transfer: snapshot.merge(status: transfer.status) }
    else
      { success: true, action: "rejected", transfer: snapshot }
    end
  end

  private
    def find_transfer(id)
      return nil unless valid_uuid?(id)

      writable_transaction_ids = family.transactions
        .joins(entry: :account)
        .merge(Account.writable_by(user))
        .select(:id)

      Transfer
        .where(inflow_transaction_id: writable_transaction_ids)
        .where(outflow_transaction_id: writable_transaction_ids)
        .find_by(id: id)
    end
end
