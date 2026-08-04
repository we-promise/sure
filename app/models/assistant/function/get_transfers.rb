class Assistant::Function::GetTransfers < Assistant::Function
  class << self
    def name = "get_transfers"
    def description = "Lists transfers between accounts accessible to the user, including ids for update_transfer and delete_transfer."
  end

  def call(_params = {})
    transaction_ids = family.transactions
      .joins(:entry)
      .where(entries: { account_id: user.accessible_accounts.visible.select(:id) })
      .select(:id)

    transfers = Transfer
      .where(inflow_transaction_id: transaction_ids, outflow_transaction_id: transaction_ids)
      .includes(inflow_transaction: { entry: :account }, outflow_transaction: { entry: :account })
      .order(created_at: :desc)
      .map do |transfer|
        {
          id: transfer.id,
          status: transfer.status,
          date: transfer.date,
          amount: transfer.outflow_transaction.entry.amount.abs,
          notes: transfer.notes,
          from_account: { id: transfer.from_account.id, name: transfer.from_account.name, currency: transfer.from_account.currency },
          to_account: { id: transfer.to_account.id, name: transfer.to_account.name, currency: transfer.to_account.currency }
        }
      end

    { transfers: transfers }
  end
end
