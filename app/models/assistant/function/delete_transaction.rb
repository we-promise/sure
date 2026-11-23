# frozen_string_literal: true

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
#
# Preview first: a call without preview_token deletes nothing and returns what
# would be removed plus a token; only a call with that token deletes (see
# PreviewToken).

class Assistant::Function::DeleteTransaction < Assistant::Function
  include Assistant::Function::PreviewToken

  annotate :destructive, idempotent: true

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

        Always two calls. First call it without preview_token: nothing is
        deleted, and it returns the transaction it would delete and a
        preview_token. Show that to the user, and only once they confirm call
        it again with the same id and that preview_token. The token expires
        after #{Assistant::Function::PreviewToken::PREVIEW_TOKEN_TTL.inspect} and is refused if the transaction
        changed since the preview.

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
        },
        preview_token: {
          type: "string",
          description: "preview_token from the preview call for this transaction. Omit it to preview; nothing is deleted without it."
        }
      }
    )
  end

  # Tool entry point. Resolves a writable transaction and, without a valid
  # preview_token, returns the preview instead of deleting. With one, destroys
  # its root ledger entry (cascading to the transaction, a split's children and
  # a transfer with its fees), enqueues the post-delete account sync
  # (best-effort), and returns { success: true, deleted: true, transaction: }
  # (with an optional :warning if the sync could not be enqueued). Errors:
  # not_found, split_child, preview_required, preview_stale, delete_aborted.
  def call(params = {})
    transaction = find_transaction(params["id"], params["account_id"])
    return error("not_found", "No transaction with id '#{params["id"]}' in an account you can write to.") unless transaction

    entry = transaction.entry
    return error("split_child", "Split child transactions cannot be deleted individually. Delete the split parent instead.") if entry.split_child?

    # The preview is both what the user confirms and the deleted record in the
    # response, taken before destruction so the response never reads destroyed
    # associations. The locks follow Entry#with_split_lock, so a resplit can't
    # change the children between the check and the destroy.
    result = confirm_with_preview(params, transaction, -> { preview(transaction, entry) }, lock: [ transaction, entry ]) do |snapshot|
      destroy_entry(entry, snapshot)
    end
    result[:deleted] ? sync_after_delete(entry, result) : result
  end

  private
    def destroy_entry(entry, snapshot)
      # Entry is the delegated_type root record; destroy! cascades to the
      # Transaction child (delegated_type ... dependent: :destroy). This is the
      # exact record the native destroy action destroys.
      entry.destroy!

      {
        success: true,
        deleted: true,
        transaction: snapshot,
        message: "Deleted #{snapshot[:name]} (#{snapshot[:amount_formatted]} on #{snapshot[:date]})."
      }
    rescue ActiveRecord::RecordNotDestroyed
      # A before_destroy guard aborted the destroy (e.g. a split child that
      # slipped past the pre-check, or another constraint). `throw :abort` in
      # a before_destroy makes destroy! raise RecordNotDestroyed — the record
      # was NOT deleted.
      error("delete_aborted", "Deletion was aborted by a record constraint; the transaction was not deleted.")
    end

    # Recalculates the account balance/sync window after the delete commits.
    # Best-effort: the transaction is ALREADY deleted, so a failure here must
    # NOT be reported as a failed deletion. sync_account_later is
    # destroyed?-safe (reads the still-loaded in-memory account).
    def sync_after_delete(entry, result)
      entry.sync_account_later
      result
    rescue StandardError => e
      result.merge(warning: "Transaction deleted, but the post-delete account sync could not be enqueued (#{e.class}). The balance will recalculate on the next sync.")
    end

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

    # What deleting the transaction removes: the transaction itself, a split's
    # children and, for a transfer leg, the transfer and its fee transactions
    # (the other leg stays and becomes a standard transaction).
    def preview(transaction, entry)
      snapshot = serialize(transaction, entry)

      children = entry.child_entries.in_split_order.to_a
      snapshot[:split_children] = children.map { |child| serialize_brief(child) } if children.any?

      if (transfer = transaction.transfer)
        counterpart = transfer.inflow_transaction_id == transaction.id ? transfer.outflow_transaction : transfer.inflow_transaction
        snapshot[:transfer] = {
          id: transfer.id,
          status: transfer.status,
          counterpart: serialize_brief(counterpart.entry),
          deleted_fee_transactions: transfer.fee_transactions.order(:id).map { |fee| serialize_brief(fee.entry) }
        }
      end

      snapshot
    end

    # Shape a Transaction (and its root entry) into the result hash returned to
    # the caller.
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
        account: entry.account.name,
        type: entry.classification
      }
    end

    def serialize_brief(entry)
      {
        id: entry.entryable_id,
        entry_id: entry.id,
        account: entry.account.name,
        name: entry.name,
        date: entry.date,
        amount: entry.amount.to_s,
        currency: entry.currency
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
