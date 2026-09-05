class Assistant::Function::DeleteTransfer < Assistant::Function
  class << self
    def name = "delete_transfer"
    def description = "Unlinks a transfer whose two accounts are writable. The underlying transactions remain available for delete_transaction."
  end

  def params_schema
    build_schema(required: [ "id" ], properties: { id: { type: "string", description: "Transfer id from get_transfers" } })
  end

  def call(params = {})
    transfer = find_family_transfer(params["id"])
    return error("not_found", "Writable transfer not found.") unless transfer

    result = Transfer.transaction do
      accounts = [ transfer.from_account, transfer.to_account ].compact
      Account::MutationAccess.lock!(accounts:, user:, level: Account::MutationAccess::WRITE)
      transfer.lock!

      id = transfer.id
      transaction_ids = [ transfer.outflow_transaction_id, transfer.inflow_transaction_id ]
      transfer.destroy!
      { id:, transaction_ids:, accounts: }
    end

    result.fetch(:accounts).each(&:sync_later)
    {
      success: true,
      deleted_transfer_id: result.fetch(:id),
      remaining_transaction_ids: result.fetch(:transaction_ids),
      message: "Transfer link deleted; underlying transactions were preserved."
    }
  rescue Account::MutationAccess::Denied
    error("not_found", "Writable transfer not found.")
  rescue ActiveRecord::RecordNotDestroyed => e
    error("delete_failed", e.record.errors.full_messages.join("; "))
  end

  private
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
