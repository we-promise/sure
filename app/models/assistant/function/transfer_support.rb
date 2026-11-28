# frozen_string_literal: true

# Shared lookups for the tools that write transfers. A transfer is reachable
# (unmatch_transfer, update_transfer) only when the user can write to both of
# its accounts; delete_transaction needs only the leg it deletes. Neither
# delete_transaction nor unmatch_transfer deletes fees the user cannot write.
module Assistant::Function::TransferSupport
  private
    def writable_transactions
      family.transactions.joins(entry: :account).merge(Account.writable_by(user))
    end

    def scoped_transfers
      ids = writable_transactions.select(:id)
      Transfer.where(inflow_transaction_id: ids).where(outflow_transaction_id: ids)
    end

    def find_transfer(id)
      return nil unless valid_uuid?(id)

      scoped_transfers.find_by(id: id)
    end

    def find_transfer_for_transaction(id)
      return nil unless valid_uuid?(id)

      scoped_transfers.where("inflow_transaction_id = :id OR outflow_transaction_id = :id", id: id).first
    end

    # Exactly one of transaction_id or transfer_id; an error hash otherwise.
    def lookup_transfer(params)
      if params["transaction_id"].present? == params["transfer_id"].present?
        return error("invalid_arguments", "Pass exactly one of transaction_id or transfer_id.")
      end

      transfer = params["transfer_id"].present? ? find_transfer(params["transfer_id"]) : find_transfer_for_transaction(params["transaction_id"])
      return transfer if transfer

      ref = params["transfer_id"].presence || params["transaction_id"]
      error("not_found", "No transfer for '#{ref}' between accounts you can write to.")
    end

    # Whether unlinking or deleting the transfer would delete a fee on an
    # account the user cannot write. Transfer::Creator puts fees only on the
    # legs' accounts, but every fee goes with the transfer, so each is checked
    # (as TransfersController checks them before an unlink).
    def unwritable_fees?(transfer)
      transfer.present? && transfer.fee_transactions.where.not(id: writable_transactions.select(:id)).exists?
    end

    def unwritable_fee_error
      error("transfer_spans_unwritable_account", "The transfer has fee transactions in an account you cannot write to, and they would be deleted with it. Nothing was changed. Someone who can write to every account involved has to do it.")
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
