# frozen_string_literal: true

# GetTransferMatchCandidates — the read half of match_transfer. Shows whether a
# transaction is already part of a transfer (including a pending auto-match
# awaiting review) and, if not, which existing transactions it could be
# matched with. Same candidate rules as the "Match transfer" dialog.
class Assistant::Function::GetTransferMatchCandidates < Assistant::Function
  include Assistant::Function::TransferMatchSupport

  class << self
    def name
      "get_transfer_match_candidates"
    end

    def description
      <<~INSTRUCTIONS
        Shows how a transaction can be matched as a transfer between the user's
        own accounts (e.g. a card payment, a loan repayment, a move to savings).

        Returns the transaction's current transfer, if any. A transfer with
        status "pending" is an auto-match Sure suggested that the user has not
        reviewed yet; confirm or reject it with review_transfer.

        Otherwise returns candidate transactions in other accounts: opposite
        direction, matching amount, within 30 days. `previously_rejected` marks a
        pairing the user already rejected, so ask before matching it.

        Use match_transfer to link the transaction with a candidate, or with
        an account that has no matching transaction (e.g. a manual loan account).
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[transaction_id],
      properties: {
        transaction_id: {
          type: "string",
          description: "Transaction ID from get_transactions."
        }
      }
    )
  end

  def call(params = {})
    transaction = find_transaction(params["transaction_id"], writable: false)
    return error("not_found", "No transaction with id '#{params["transaction_id"]}' in an account you can access.") unless transaction

    result = { success: true, transaction: serialize_transaction(transaction) }

    if (transfer = transaction.transfer)
      result[:transfer] = serialize_transfer(transfer, from: transaction)
      result[:candidates] = []
      return result
    end

    matcher = Transfer::Matcher.new(transaction)
    rows = matcher.candidates
    counterparts = Transaction.includes(entry: :account).where(id: rows.map { |row| matcher.counterpart_id(row) }).index_by(&:id)

    result[:candidates] = rows.filter_map do |row|
      counterpart = counterparts[matcher.counterpart_id(row)]
      next unless counterpart && accessible_account_ids.include?(counterpart.entry.account_id)

      serialize_transaction(counterpart).merge(
        days_apart: row.date_diff.to_i,
        previously_rejected: row.rejected_transfer_id.present?
      )
    end

    result
  end
end
