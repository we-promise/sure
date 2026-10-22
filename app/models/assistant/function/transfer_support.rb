# frozen_string_literal: true

# Shared lookups for the transfer tools (unmatch_transfer, update_transfer):
# a transfer is reachable only when the user can write to both of its accounts.
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

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
