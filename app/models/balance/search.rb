class Balance::Search
  include ScopedSearch

  attribute :account_id, :string
  attribute :currency, :string
  attribute :start_date, :date
  attribute :end_date, :date

  def balances_scope
    relation = scope
    relation = relation.where(account_id:) unless account_id.nil?
    relation = relation.where(currency: currency.upcase) unless currency.nil?
    within_range(relation, :date, start_date, end_date)
  end
end
