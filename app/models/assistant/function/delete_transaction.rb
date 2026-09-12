# frozen_string_literal: true

# AI-ASSISTED: written with AI assistance (Claude) and manually reviewed and
# tested by its author against a live 0.7.5-alpha.7 deployment.

# DeleteTransaction — a Sure Assistant MCP tool that permanently deletes a
# transaction, mirroring the native Api::V1::TransactionsController#destroy.
#
# ID contract: takes the SAME id that create_transaction returns, which is the
# Transaction UUID (serialize returns `id: transaction.id`). It resolves the
# Transaction, then destroys the Transaction's root ledger Entry — the exact
# record the native controller destroys — which cascades to the Transaction
# child via `delegated_type :entryable, dependent: :destroy`.
#
# Authorization: the *** endpoint enforces a single `read_write` OAuth scope
# for every tool, so this tool enforces the *write* gate itself by resolving
# only through accounts the user can write to (owner or full_control share),
# consistent with CreateTransaction. A read-only shared account, a cross-family
# id, or an unknown id all resolve to a safe `not_found` without leaking
# whether the record exists.

class Assistant::Function::DeleteTransaction < Assistant::Function
  class << self
    # The tool's stable name; this is the MCP function identifier callers use.
    def name
      "delete_transaction"
    end

    # Human/LLM-facing description of what the tool does and how to call it.
    def description
      <<~INSTRUCTIONS
        Permanently deletes a transaction from the ledger. This is destructive
        and irreversible: the transaction and its ledger entry are removed and
        the account balance is recalculated.

        Use get_transactions first to find the transaction id (the same id
        create_transaction returns). Optionally pass account_id as a guard so a
        mismatched id cannot delete the wrong record.

        It deletes the transaction's root ledger entry, which cascades to the
        transaction. It will not delete a split child transaction individually —
        delete the split parent instead.
      INSTRUCTIONS
    end
  end

  # This tool is not strict: it validates its own inputs and returns structured
  # error hashes rather than raising, so a bad call is reported to the model.
  def strict_mode?
    false
  end

  # JSON schema of the parameters this tool accepts, exposed to the model.
  def params_schema
    build_schema(
      required: %w[id],
      properties: {
        id: {
          type: "string",
          description: "Transaction ID from get_transactions (the same ID create_transaction returns)."
        },
        account_id: {
          type: "string",
          description: "Optional guard. If provided, the transaction must also belong to this writable account; a mismatch returns not_found."
        }
      }
    )
  end

  # Tool entry point. Resolves a writable transaction, snapshots it, destroys
  # its root ledger entry (cascading to the transaction), enqueues the
  # post-delete account sync (best-effort), and returns a result hash. Returns
  # { success: true, deleted: true, transaction: } on success (with an optional
  # :warning if the sync could not be enqueued), or an error hash for
  # not_found / split_child / delete_aborted.
  def call(params = {})
    transaction = find_transaction(params["id"], params["account_id"])
    return error("not_found", "No transaction with id '#{params["id"]}' in an account you can write to.") unless transaction

    entry = transaction.entry
    return error("split_child", "Split child transactions cannot be deleted individually. Delete the split parent instead.") if entry.split_child?

    # Snapshot before destruction so the response never reads destroyed
    # associations or triggers lazy loads on a deleted record.
    snapshot = serialize(transaction, entry)

    # 1) Destroy. Entry is the delegated_type root record; destroy! cascades
    #    to the Transaction child (delegated_type ... dependent: :destroy) and
    #    wraps itself in a transaction (atomic: fully destroyed or it raises).
    #    This is the exact record the native destroy action destroys.
    begin
      entry.destroy!
    rescue ActiveRecord::RecordNotDestroyed
      # A before_destroy guard aborted the destroy (e.g. a split child that
      # slipped past the pre-check, or another constraint). `throw :abort` in
      # a before_destroy makes destroy! raise RecordNotDestroyed — the record
      # was NOT deleted.
      return error("delete_aborted", "Deletion was aborted by a record constraint; the transaction was not deleted.")
    end

    # 2) Recalculate the account balance/sync window. This is best-effort: the
    #    transaction is ALREADY deleted at this point, so a failure here must
    #    NOT be reported as a failed deletion. sync_account_later is
    #    destroyed?-safe (reads the still-loaded in-memory account).
    sync_warning = nil
    begin
      entry.sync_account_later
    rescue StandardError => e
      sync_warning = "Transaction deleted, but the post-delete account sync could not be enqueued (#{e.class}). The balance will recalculate on the next sync."
    end

    response = {
      success: true,
      deleted: true,
      transaction: snapshot,
      message: "Deleted #{snapshot[:name]} (#{snapshot[:amount_formatted]} on #{snapshot[:date]})."
    }
    response[:warning] = sync_warning if sync_warning
    response
  end

  private
    # Resolve a Transaction by id, scoped to accounts the user can WRITE to
    # (owner or full_control share) — the same write gate CreateTransaction
    # uses. `merge(Account.writable_by(user))` is the native set_transaction
    # pattern (which uses accessible_by) tightened to the write set, so a
    # read-only shared account simply yields nil -> not_found. An optional
    # account_id narrows the query so a mismatched id cannot delete the wrong
    # record. Returns nil if the id is not a valid UUID or is not found.
    def find_transaction(id, account_id)
      return nil unless valid_uuid?(id)

      query = family.transactions
        .joins(entry: :account)
        .merge(Account.writable_by(user))

      if account_id.present?
        return nil unless valid_uuid?(account_id)

        query = query.where(entries: { account_id: account_id })
      end

      query.find_by(id: id)
    end

    # Shape a Transaction (and its root entry) into the result hash returned to
    # the caller. Called BEFORE destruction so the response carries a complete
    # snapshot of what was deleted.
    def serialize(transaction, entry)
      {
        id: transaction.id,
        entry_id: entry.id,
        account_id: entry.account_id,
        name: entry.name,
        date: entry.date,
        amount: entry.amount.to_s,
        amount_formatted: format_money(entry),
        currency: entry.currency,
        type: entry.classification
      }
    end

    # Human-formatted money string for the entry's amount and currency, with a
    # plain "amount currency" fallback if formatting fails.
    def format_money(entry)
      entry.amount_money.format
    rescue StandardError
      "#{entry.amount} #{entry.currency}"
    end

    # Build a standard error result hash: { success: false, error:, message: }.
    def error(key, message)
      { success: false, error: key, message: message }
    end
end
