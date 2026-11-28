# frozen_string_literal: true

# Shared lookup, permission and serialization for the split tools
# (split_transaction, unsplit_transaction). They make the same model calls as
# the web split editor and Api::V1::SplitsController: Entry#split_once!,
# Entry#resplit! and Entry#unsplit_once!, which lock the parent so two callers
# can't both insert children.
module Assistant::Function::SplitSupport
  private
    # Accessible, visible transactions only, same as update_transaction.
    def find_split_transaction(id)
      return nil unless valid_uuid?(id)

      family.transactions
        .joins(:entry)
        .includes(:entry)
        .where(entries: { account_id: user.accessible_accounts.visible.select(:id) })
        .find_by(id: id)
    end

    # A caller holding any id from the split (a child's, say, from
    # get_transactions) operates on the whole split, as in the web editor.
    def resolve_split_parent(transaction)
      entry = transaction.entry
      return [ transaction, entry ] unless entry.split_child?

      parent = entry.parent_entry
      [ parent.transaction, parent ]
    end

    # Splitting rewrites the ledger view of the account, so it needs the same
    # access as renaming a transaction: owner or full control.
    def permitted_to_split?(account)
      account.permission_for(user).in?([ :owner, :full_control ])
    end

    # Not memoized: the assistant reuses a function instance across tool
    # rounds, and a category created in an earlier round must be accepted.
    def split_references
      Entry::SplitReferences.for_user(family, user)
    end

    # The split is committed by the time the sync is enqueued, so a failure to
    # enqueue is reported as a warning rather than as a failed call.
    def split_response(entry, message)
      sync_warning = nil
      begin
        entry.sync_account_later
      rescue StandardError => e
        sync_warning = "The change was saved, but the account sync could not be enqueued (#{e.class}). Balances will recalculate on the next sync."
      end

      response = { success: true, transaction: serialize_split(entry.reload), message: message }
      response[:warning] = sync_warning if sync_warning
      response
    end

    def not_splittable_reason(transaction, entry)
      return "Transaction is part of a transfer" if transaction.transfer?
      return "Transaction is already split" if entry.split_parent?
      return "Transaction is pending" if transaction.pending?
      return "Transaction is excluded" if entry.excluded?

      "Transaction is not splittable"
    end

    def serialize_split(entry)
      children = Transaction
        .joins(:entry)
        .where(entries: { parent_entry_id: entry.id })
        .preload(:entry, :category, :merchant, :tags)
        .order("entries.created_at")

      {
        id: entry.entryable_id,
        name: entry.name,
        date: entry.date,
        amount: entry.amount.to_s,
        currency: entry.currency,
        split: entry.split_parent?,
        excluded: entry.excluded,
        children: children.map { |child| serialize_split_child(child) }
      }
    end

    def serialize_split_child(transaction)
      entry = transaction.entry
      {
        id: transaction.id,
        name: entry.name,
        amount: entry.amount.to_s,
        excluded: entry.excluded,
        category: transaction.category && { id: transaction.category.id, name: transaction.category.name },
        merchant: transaction.merchant && { id: transaction.merchant.id, name: transaction.merchant.name },
        tags: transaction.tags.map { |tag| { id: tag.id, name: tag.name } }
      }
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
