class Assistant::Function::LinkTransfer < Assistant::Function
  class << self
    def name
      "link_transfer"
    end

    def description
      <<~INSTRUCTIONS
        Use this to link two existing transactions together as a transfer.

        A transfer represents money moving between two accounts (e.g. a payment from
        checking to a credit card, a funds movement between savings accounts, or a
        loan payment).

        Both transactions must:
        - Belong to different accounts within the same family
        - Have opposite amounts (one positive, one negative) in the same or different currencies
        - Be within 30 days of each other

        The function will automatically determine which transaction is the inflow
        (negative amount — receives money) and which is the outflow (positive amount —
        sends money), and update their `kind` fields accordingly.

        Example:

        ```
        link_transfer({
          transaction_id: "uuid-of-first-transaction",
          other_transaction_id: "uuid-of-second-transaction"
        })
        ```
      INSTRUCTIONS
    end
  end

  def params_schema
    build_schema(
      required: [ "transaction_id", "other_transaction_id" ],
      properties: {
        transaction_id: {
          type: "string",
          description: "UUID of the first transaction to link"
        },
        other_transaction_id: {
          type: "string",
          description: "UUID of the second transaction to link as the transfer counterpart"
        }
      }
    )
  end

  def call(params = {})
    transaction_id = params["transaction_id"]
    other_transaction_id = params["other_transaction_id"]

    txn_a = family.transactions.find(transaction_id)
    txn_b = family.transactions.find(other_transaction_id)

    if txn_a.transfer.present?
      return { error: "Transaction #{transaction_id} is already linked to a transfer" }
    end

    if txn_b.transfer.present?
      return { error: "Transaction #{other_transaction_id} is already linked to a transfer" }
    end

    inflow_txn, outflow_txn = assign_inflow_outflow(txn_a, txn_b)

    transfer = Transfer.new(
      inflow_transaction: inflow_txn,
      outflow_transaction: outflow_txn,
      status: "confirmed"
    )

    Transfer.transaction do
      transfer.save!

      destination_account = transfer.inflow_transaction.entry.account
      outflow_kind = Transfer.kind_for_account(destination_account)
      outflow_attrs = { kind: outflow_kind }

      if outflow_kind == "investment_contribution"
        category = destination_account.family.investment_contributions_category
        outflow_attrs[:category] = category if category.present? && transfer.outflow_transaction.category_id.blank?
      end

      transfer.outflow_transaction.update!(outflow_attrs)
      transfer.inflow_transaction.update!(kind: "funds_movement")
    end

    transfer.sync_account_later

    {
      success: true,
      transfer_id: transfer.id,
      inflow_transaction_id: inflow_txn.id,
      outflow_transaction_id: outflow_txn.id,
      message: "Transactions successfully linked as a transfer"
    }
  rescue ActiveRecord::RecordNotFound => e
    { error: "Transaction not found: #{e.message}" }
  rescue ActiveRecord::RecordInvalid => e
    { error: e.record.errors.full_messages.join(", ") }
  rescue => e
    { error: "Unexpected error: #{e.message}" }
  end

  private

    def assign_inflow_outflow(txn_a, txn_b)
      if txn_a.entry.amount.negative?
        [ txn_a, txn_b ]
      else
        [ txn_b, txn_a ]
      end
    end
end
