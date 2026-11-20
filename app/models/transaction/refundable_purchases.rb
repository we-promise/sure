# Purchase candidates a refund can link to: posted, standard, outgoing
# transactions that are not transfers, split parents, or pending. Shared by
# the refund-linking dialog and the new-transaction form so both offer the
# same list.
class Transaction::RefundablePurchases
  DEFAULT_LIMIT = 100

  def initialize(entries:, search: nil, limit: DEFAULT_LIMIT)
    @entries = entries
    @search = search.is_a?(String) ? search.strip.presence : nil
    @limit = limit
  end

  def call
    scope = entries
      .where(entryable_type: "Transaction", excluded: false)
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
      .where(transactions: { kind: "standard" })
      .where(<<~SQL.squish)
        NOT EXISTS (
          SELECT 1 FROM transfers
          WHERE transfers.inflow_transaction_id = transactions.id
             OR transfers.outflow_transaction_id = transactions.id
        )
      SQL
      .where("entries.amount > 0")
      .excluding_split_parents
      .excluding_pending

    if search.present?
      scope = scope.where("entries.name ILIKE ?", "%#{Entry.sanitize_sql_like(search)}%")
    end

    scope
      .reorder(date: :desc, created_at: :desc, id: :desc)
      .preload(:account, :entryable)
      .limit(limit)
      .to_a
  end

  private
    attr_reader :entries, :search, :limit
end
