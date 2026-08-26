class Assistant::Function::DeleteTransaction < Assistant::Function
  class << self
    def name
      "delete_transaction"
    end

    def description
      <<~INSTRUCTIONS
        Deletes a standard income or expense transaction.

        Use get_transactions first to find the transaction id. Linked transfers and
        split transactions must be removed with their dedicated workflows instead.
        This action permanently removes the transaction.
      INSTRUCTIONS
    end
  end

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: {
          type: "string",
          description: "Transaction ID from get_transactions"
        }
      }
    )
  end

  def call(params = {})
    transaction = find_transaction(params["id"])
    return error("not_found", "Transaction with id '#{params["id"]}' not found.") unless transaction

    entry = transaction.entry
    result = nil
    transaction_id = nil
    transaction_name = nil

    Entry.transaction do
      entry.lock!
      transaction.lock!
      entry.association(:entryable).target = transaction

      unless entry.account.permission_for(user).in?([ :owner, :full_control ])
        result = error("not_authorized", "You do not have permission to delete this transaction.")
        next
      end
      if entry.split_child? || entry.split_parent?
        result = error("split_transaction", "Split transactions must be deleted with the split editor.")
        next
      end
      if transaction.transfer.present?
        result = error("transfer_transaction", "Linked transfers must be deleted with delete_transfer.")
        next
      end

      transaction_id = transaction.id
      transaction_name = entry.name
      entry.destroy!
    end
    return result if result

    entry.sync_account_later
    {
      success: true,
      deleted_transaction_id: transaction_id,
      message: "Transaction '#{transaction_name}' deleted."
    }
  rescue ActiveRecord::RecordNotFound
    error("not_found", "Transaction with id '#{params["id"]}' not found.")
  rescue ActiveRecord::RecordNotDestroyed => e
    error("delete_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def find_transaction(id)
      return nil unless valid_uuid?(id)

      family.transactions
        .joins(:entry)
        .where(entries: { account_id: user.accessible_accounts.visible.select(:id) })
        .find_by(id: id)
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
