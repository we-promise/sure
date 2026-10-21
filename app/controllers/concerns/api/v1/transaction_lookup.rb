# frozen_string_literal: true

# Family- and share-scoped transaction lookup, shared by the controllers that
# address a transaction by id so the scoping has one place to change.
module Api::V1::TransactionLookup
  extend ActiveSupport::Concern

  private

    def load_accessible_transaction(id)
      raise ActiveRecord::RecordNotFound unless valid_uuid?(id)

      family = current_resource_owner.family
      @transaction = family.transactions
        .joins(entry: :account)
        .merge(Account.accessible_by(current_resource_owner))
        .find(id)
      @entry = @transaction.entry
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Transaction not found"
      }, status: :not_found
    end

    # Entry ids among `transactions` that have split children, as a Set, in one
    # query that loads no child rows. The transaction partial reads it for
    # `split_parent`.
    def split_parent_entry_ids_for(transactions)
      Entry.split_parent_ids_among(transactions.map { |transaction| transaction.entry.id })
    end
end
