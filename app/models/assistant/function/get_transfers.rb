class Assistant::Function::GetTransfers < Assistant::Function
  DEFAULT_LIMIT = 100
  MAX_LIMIT = 200

  class << self
    def name = "get_transfers"
    def description = "Lists transfers between accounts accessible to the user, including ids for update_transfer and delete_transfer."
  end

  def params_schema
    build_schema(
      properties: {
        limit: { type: "integer", minimum: 1, maximum: MAX_LIMIT, description: "Maximum transfers to return (default: #{DEFAULT_LIMIT})." }
      }
    )
  end

  def strict_mode? = false

  def call(params = {})
    limit = Integer(params.fetch("limit", DEFAULT_LIMIT), exception: false)
    return { success: false, error: "invalid_parameters", message: "limit must be between 1 and #{MAX_LIMIT}." } unless limit&.between?(1, MAX_LIMIT)

    transfers = Transfer
      .for_family(family)
      .between_accounts(user.accessible_accounts.visible.select(:id))
      .includes(inflow_transaction: { entry: :account }, outflow_transaction: { entry: :account })
      .order(created_at: :desc)
      .limit(limit)
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
