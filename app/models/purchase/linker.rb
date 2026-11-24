# Links a purchase to the transaction that paid for it and classifies that transaction by what
# was bought: one category is set and locked, several split the transaction. Categories set by
# rules, AI or other automatic sources are replaced; a transaction the user already split or
# categorized by hand is linked without being changed, until the user asks for the order's
# categories (apply_categories!).
class Purchase::Linker
  def initialize(purchase)
    @purchase = purchase
  end

  def link!(entry, manual: false)
    transaction = entry.entryable
    raise Purchase::LinkError, "Only transactions can be linked" unless transaction.is_a?(Transaction)

    Purchase.transaction do
      # Checked on the locked purchase: a family transfer may have moved it since it was loaded.
      purchase.lock!
      raise Purchase::LinkError, "The account can't be changed by this user" unless annotatable?(entry)
      existing = Purchase.where(transaction_id: transaction.id).where.not(id: purchase.id)
      raise Purchase::LinkError, "The transaction already belongs to another purchase" if existing.exists?
      # Linking elsewhere would leave the first transaction carrying this purchase: unlink first.
      if purchase.transaction_id.present? && purchase.transaction_id != transaction.id
        raise Purchase::LinkError, "The purchase is already linked to another transaction"
      end

      purchase.update!(
        linked_transaction: transaction,
        status: :matched,
        matched_at: Time.current,
        match_candidate_entry_ids: []
      )
      transaction.update!(extra: transaction.extra.merge("purchase" => summary))
      forget_candidate_elsewhere(entry)
      attach_receipt_files(transaction)

      if (reason = mismatch_reason(entry))
        purchase.flag!(reason, entry_id: entry.id) if manual
      else
        categorize(entry)
      end
    end
  end

  # True when the order's categories weren't applied only because the user had chosen the
  # transaction's category, and applying them would change it.
  def categories_held_back?
    transaction = purchase.linked_transaction
    return false unless purchase.matched? && transaction

    entry = transaction.entry
    return false if entry.split_parent? || entry.split_child? || mismatch_reason(entry) || !transaction.category_set_by_user?

    groups = allocation
    groups.many? || (groups.one? && groups.first[:category].present? && groups.first[:category].id != transaction.category_id)
  end

  # Applies the order's categories over the one the user chose, when they ask for it.
  def apply_categories!(user)
    Purchase.transaction do
      purchase.lock!
      transaction = purchase.linked_transaction
      raise Purchase::LinkError, "The purchase isn't linked to a transaction" unless purchase.matched? && transaction

      entry = transaction.entry
      raise Purchase::LinkError, "The account can't be changed by this user" unless annotatable?(entry, user)
      raise Purchase::LinkError, "The transaction doesn't match the order" if mismatch_reason(entry)

      categorize(entry, override_user: true)
    end
  end

  def unlink!
    Purchase.transaction do
      purchase.lock!
      transaction = purchase.linked_transaction
      if transaction
        transaction.update!(extra: transaction.extra.except("purchase"))
        detach_receipt_files(transaction)
        rejected = purchase.rejected_entry_ids | [ transaction.entry.id ]
      end

      purchase.update!(
        linked_transaction: nil,
        matched_at: nil,
        rejected_entry_ids: rejected || purchase.rejected_entry_ids,
        status: purchase.email? ? :awaiting_payment : :unmatched
      )
    end
  end

  private
    attr_reader :purchase

    # The receipt goes along with the payment, unless the transaction has no room left for it.
    def attach_receipt_files(transaction)
      blobs = purchase.receipt_files.blobs.where.not(id: transaction.attachments_attachments.select(:blob_id)).to_a
      return if blobs.empty?

      if transaction.attachments.count + blobs.size > Transaction::MAX_ATTACHMENTS_PER_TRANSACTION
        purchase.flag!(:too_many_attachments, entry_id: transaction.entry.id)
      else
        transaction.attachments.attach(blobs)
      end
    end

    # Removes only the attachment records: the files stay on the purchase.
    def detach_receipt_files(transaction)
      transaction.attachments_attachments.where(blob_id: purchase.receipt_files.blobs.select(:id)).delete_all
    end

    # Other purchases waiting for a pick (e.g. an identical order) no longer offer this entry.
    def forget_candidate_elsewhere(entry)
      Purchase.where(family_id: purchase.family_id).where.not(id: purchase.id)
        .where("? = ANY(match_candidate_entry_ids)", entry.id)
        .update_all([ "match_candidate_entry_ids = array_remove(match_candidate_entry_ids, ?::uuid), updated_at = ?", entry.id, Time.current ])
    end

    def annotatable?(entry, user = purchase.user)
      Account.annotatable_by(user).where(id: entry.account_id, family_id: purchase.family_id).exists?
    end

    def summary
      { "purchase_id" => purchase.id, "merchant" => purchase.merchant, "order_number" => purchase.order_number }
    end

    # Why the purchase's items can't be applied to this entry, or nil when they can.
    def mismatch_reason(entry)
      transaction = entry.entryable
      if purchase.total.nil? || entry.amount != purchase.total || entry.currency != purchase.currency
        :amount_differs
      elsif transaction.pending?
        :pending
      elsif transaction.transfer?
        :transfer
      end
    end

    def categorize(entry, override_user: false)
      transaction = entry.entryable
      return if entry.split_parent? || entry.split_child?
      return if !override_user && transaction.category_set_by_user?

      groups = allocation
      if groups.one?
        category = groups.first[:category]
        return unless category

        transaction.enrich_attribute(:category_id, category.id, source: "purchase", ignore_locks: true)
        transaction.lock_attr!(:category_id)
      elsif groups.many?
        entry.split_once!(groups.map { |group| split_for(group) }, lock_attributes: true)
      end
    end

    def allocation
      Purchase::CategoryAllocator.new(total: purchase.total, items: allocator_items, categories: purchase.family.categories).groups
    end

    def allocator_items
      purchase.items.includes(:category).map do |item|
        { "name" => item.name, "amount" => item.amount.to_s, "category_name" => item.category&.name }
      end
    end

    def split_for(group)
      label = group[:category]&.name || I18n.t("purchases.uncategorized_split_name")
      { name: [ purchase.merchant, label ].compact.join(" — "), amount: group[:amount], category_id: group[:category]&.id }
    end
end
