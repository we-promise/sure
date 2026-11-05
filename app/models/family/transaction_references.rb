# Category, merchant and tag ids reach the transaction forms as raw ids. These
# lookups resolve them through the family, so a crafted request can't attach
# another family's records to a transaction. Each one returns nil (or drops the
# id) for anything the family can't use; callers decide whether that is a 404.
module Family::TransactionReferences
  extend ActiveSupport::Concern

  def transaction_category_id_for(id)
    return if id.blank?

    categories.where(id: id).pick(:id)
  end

  # Merchants follow the form's picker (#available_merchants_for), which also
  # offers provider merchants on transactions the user can see.
  def transaction_merchant_id_for(id, user:)
    return if id.blank?

    available_merchants_for(user).where(id: id).pick(:id)
  end

  def transaction_tag_ids_for(ids)
    tags.where(id: Array(ids).compact_blank).pluck(:id)
  end
end
