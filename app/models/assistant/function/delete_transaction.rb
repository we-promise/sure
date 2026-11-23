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
        Optionally pass account_id as a safety guard against deleting from the wrong account.
        This action permanently removes the transaction.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: {
          type: "string",
          description: "Transaction ID from get_transactions"
        },
        account_id: {
          type: "string",
          description: "Optional safety guard: the transaction must belong to this writable account"
        }
      }
    )
  end

  def call(params = {})
    transaction = find_transaction(params["id"])
    return error("not_found", "Transaction with id '#{params["id"]}' not found.") unless transaction

    entry = transaction.entry
    account_id = entry.account_id
    if !params["account_id"].nil? && (!valid_uuid?(params["account_id"]) || params["account_id"] != account_id)
      return error("not_found", "Transaction not found in the specified account.")
    end
    result = nil
    transaction_id = nil
    transaction_name = nil
    snapshot = nil

    Entry.transaction do
      Account::MutationAccess.lock!(accounts: [ entry.account ], user:, level: Account::MutationAccess::WRITE)
      entry.lock!
      transaction.lock!
      if entry.account_id != account_id
        result = error("not_found", "The transaction's account changed before deletion.")
        next
      end
      entry.association(:entryable).target = transaction

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
      snapshot = {
        id: transaction.id, entry_id: entry.id, account_id: entry.account_id,
        name: entry.name, date: entry.date, amount: entry.amount.to_s,
        amount_formatted: format_money(entry), currency: entry.currency, type: entry.classification
      }
      entry.destroy!
    end
    return result if result

    response = {
      success: true,
      deleted: true,
      transaction: snapshot,
      deleted_transaction_id: transaction_id,
      message: "Transaction '#{transaction_name}' deleted."
    }
    begin
      entry.sync_account_later
    rescue StandardError => e
      response[:warning] = "Transaction deleted, but the post-delete account sync could not be enqueued (#{e.class}). The balance will recalculate on the next sync."
    end
    response
  rescue Account::MutationAccess::Denied
    error("not_authorized", "You do not have permission to delete this transaction.")
  rescue ActiveRecord::RecordNotFound
    error("not_found", "Transaction with id '#{params["id"]}' not found.")
  rescue ActiveRecord::RecordNotDestroyed => e
    error("delete_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def format_money(entry)
      entry.amount_money.format
    rescue StandardError
      "#{entry.amount} #{entry.currency}"
    end

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
