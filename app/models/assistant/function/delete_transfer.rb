class Assistant::Function::DeleteTransfer < Assistant::Function
  class << self
    def name = "delete_transfer"

    def description
      "Unlinks a transfer whose two accounts are writable. The two underlying transactions remain and can then be removed with delete_transaction."
    end
  end

  def params_schema
    build_schema(required: [ "id" ], properties: { id: { type: "string", description: "Transfer id from get_transfers" } })
  end

  def call(params = {})
    transfer = find_writable_transfer(params["id"])
    return error("not_found", "Writable transfer not found.") unless transfer

    id = transfer.id
    outflow_id = transfer.outflow_transaction_id
    inflow_id = transfer.inflow_transaction_id
    transfer.destroy!

    {
      success: true,
      deleted_transfer_id: id,
      remaining_transaction_ids: [ outflow_id, inflow_id ],
      message: "Transfer link deleted; underlying transactions were preserved."
    }
  rescue ActiveRecord::RecordNotDestroyed => e
    error("delete_failed", e.record.errors.full_messages.join("; "))
  end

  private
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
