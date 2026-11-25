class RecurringTransaction::Search
  include ScopedSearch

  attribute :status, :string
  attribute :account_id, :string

  def recurring_transactions_scope
    relation = scope
    relation = relation.where(status:) unless status.nil?
    relation = relation.where(account_id:) unless account_id.nil?
    relation
  end
end
