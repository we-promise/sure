# frozen_string_literal: true

# UnmatchTransfer — unlinks a transfer between two of the family's
# transactions, confirmed or pending, so a wrong match can be undone (e.g. a
# card payment paired with the account that funded it rather than the one that
# paid it). Both transactions stay in the ledger; a confirmed transfer's
# become standard transactions again (a pending match never changed their
# kinds, so those stay). Balances don't change.
#
# By default it rejects the pairing (Transfer#reject!, the Reject button), so
# auto-match won't suggest it again. reject: false only unlinks
# (Transfer#destroy!, as TransfersController#destroy does).
#
# Transfer fee transactions belong to the transfer and are deleted with it, as
# in the UI; the result lists them and the affected accounts are resynced.
class Assistant::Function::UnmatchTransfer < Assistant::Function
  class << self
    def name
      "unmatch_transfer"
    end

    def description
      <<~INSTRUCTIONS
        Unlinks a transfer (or a credit card or loan payment) between two of
        the user's accounts, so its two transactions count as ordinary income
        and spending again. Use it to undo a wrong match: the transactions are
        kept, and can then be matched with the right counterparts.

        Pass the id of either transaction in the transfer (get_transactions
        marks them is_transfer), or the transfer_id. Works on confirmed and
        pending transfers. Both accounts must be writable.

        By default the pairing is also recorded as rejected, so Sure's
        auto-match won't suggest it again; pass reject: false to only unlink.
        Fee transactions attached to the transfer are deleted with it (listed
        in the result). Pass dry_run: true to see the effect first.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      properties: {
        transaction_id: {
          type: "string",
          description: "ID of either transaction in the transfer, from get_transactions. Omit when passing transfer_id."
        },
        transfer_id: {
          type: "string",
          description: "Transfer ID. Omit when passing transaction_id."
        },
        reject: {
          type: "boolean",
          description: "Also stop auto-match from suggesting this pairing again. Defaults to true."
        },
        dry_run: {
          type: "boolean",
          description: "Describe the change without making it. Defaults to false."
        }
      }
    )
  end

  def call(params = {})
    if params["transaction_id"].present? == params["transfer_id"].present?
      return error("invalid_arguments", "Pass exactly one of transaction_id or transfer_id.")
    end

    transfer = params["transfer_id"].present? ? find_transfer(params["transfer_id"]) : find_transfer_for_transaction(params["transaction_id"])
    unless transfer
      ref = params["transfer_id"].presence || params["transaction_id"]
      return error("not_found", "No transfer for '#{ref}' between accounts you can write to.")
    end

    # Only an explicit false skips the rejection; null counts as omitted.
    reject = params["reject"].nil? || ActiveModel::Type::Boolean.new.cast(params["reject"])

    if ActiveModel::Type::Boolean.new.cast(params["dry_run"])
      snapshot = serialize_transfer(transfer)
      return { success: true, dry_run: true, reject: reject, transfer: snapshot, message: "Would unlink #{snapshot[:name]}." }
    end

    # Lock, then re-find within the writable scope: two concurrent calls can't
    # both act on the transfer, a fee attached meanwhile is reported, and
    # write access lost since the lookup is caught.
    snapshot = accounts = nil
    unmatched = Transfer.uncached do
      Transfer.transaction do
        locked = scoped_transfers.lock.find_by(id: transfer.id)
        next false unless locked

        snapshot = serialize_transfer(locked)
        accounts = ([ locked.from_account, locked.to_account ] + locked.fee_transactions.map { |t| t.entry.account }).compact.uniq
        reject ? locked.reject! : locked.destroy!
        true
      end
    end
    return error("not_found", "The transfer was already unlinked, or you can no longer write to its accounts.") unless unmatched

    # A pending match never changed the kinds, so report what they are now.
    kinds = Transaction.where(id: [ snapshot[:outflow][:id], snapshot[:inflow][:id] ]).pluck(:id, :kind).to_h
    snapshot[:outflow][:kind_after] = kinds[snapshot[:outflow][:id]]
    snapshot[:inflow][:kind_after] = kinds[snapshot[:inflow][:id]]

    response = {
      success: true,
      unmatched: true,
      rejected: reject,
      transfer: snapshot,
      message: "Unlinked #{snapshot[:name]}. Outflow kind is now #{snapshot[:outflow][:kind_after]}, inflow kind #{snapshot[:inflow][:kind_after]}."
    }

    # Best-effort: the unlink has already committed.
    if snapshot[:deleted_fee_transactions].any?
      begin
        accounts.each(&:sync_later)
      rescue StandardError => e
        response[:warning] = "Transfer unlinked, but the account sync for the deleted fees could not be enqueued (#{e.class}). Balances will recalculate on the next sync."
      end
    end

    response
  end

  private
    def writable_transactions
      family.transactions.joins(entry: :account).merge(Account.writable_by(user))
    end

    def scoped_transfers
      ids = writable_transactions.select(:id)
      Transfer.where(inflow_transaction_id: ids).where(outflow_transaction_id: ids)
    end

    def find_transfer(id)
      return nil unless valid_uuid?(id)

      scoped_transfers.find_by(id: id)
    end

    def find_transfer_for_transaction(id)
      return nil unless valid_uuid?(id)

      scoped_transfers.where("inflow_transaction_id = :id OR outflow_transaction_id = :id", id: id).first
    end

    def serialize_transfer(transfer)
      {
        id: transfer.id,
        name: transfer.name,
        status: transfer.status,
        outflow: serialize_transaction(transfer.outflow_transaction),
        inflow: serialize_transaction(transfer.inflow_transaction),
        deleted_fee_transactions: transfer.fee_transactions.map { |t| serialize_transaction(t) }
      }
    end

    def serialize_transaction(transaction)
      entry = transaction.entry
      {
        id: transaction.id,
        account_id: entry.account_id,
        account: entry.account.name,
        name: entry.name,
        date: entry.date,
        amount: entry.amount.abs.to_s,
        amount_formatted: entry.amount_money.abs.format,
        currency: entry.currency,
        kind: transaction.kind
      }
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
