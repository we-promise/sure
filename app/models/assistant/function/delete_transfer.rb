class Assistant::Function::DeleteTransfer < Assistant::Function
  class << self
    def name = "delete_transfer"

    def description
      <<~INSTRUCTIONS
        Unlinks a transfer whose accounts are writable. Principal transactions
        remain available for delete_transaction, but associated fee transactions
        are permanently deleted and listed in deleted_fee_transactions.
        Confirm the fee deletion with the user before calling this tool.
      INSTRUCTIONS
    end
  end

  def params_schema
    build_schema(required: [ "id" ], properties: { id: { type: "string", description: "Transfer ID from get_transfers" } })
  end

  def call(params = {})
    response = Assistant::Function::UnmatchTransfer.new(user).call("transfer_id" => params["id"], "reject" => false)
    return response unless response[:success]

    snapshot = response.fetch(:transfer)
    fees = snapshot.fetch(:deleted_fee_transactions)
    principal = [ snapshot.fetch(:outflow), snapshot.fetch(:inflow) ]
    # UnmatchTransfer already resyncs all affected accounts when fees were deleted.
    if fees.empty?
      begin
        family.accounts.where(id: principal.pluck(:account_id)).each(&:sync_later)
      rescue StandardError => e
        response[:warning] = "Transfer unlinked, but the account sync could not be enqueued (#{e.class}). Balances will recalculate on the next sync."
      end
    end

    response.merge(
      deleted_transfer_id: snapshot.fetch(:id),
      remaining_transaction_ids: principal.pluck(:id),
      deleted_fee_transactions: fees,
      message: "Transfer link deleted; principal transactions were preserved. Associated fee transactions were deleted as listed in deleted_fee_transactions."
    )
  rescue ActiveRecord::RecordNotDestroyed => e
    { success: false, error: "delete_failed", message: e.record.errors.full_messages.join("; ") }
  end
end
