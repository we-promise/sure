# Filters valuation entries (Entry rows whose entryable is a Valuation).
class Valuation::Search
  include ScopedSearch

  attribute :account_id, :string
  attribute :start_date, :date
  attribute :end_date, :date

  def valuations_scope
    relation = scope
    relation = relation.where(account_id:) unless account_id.nil?
    relation = relation.where(date: start_date..end_date) if start_date || end_date
    relation
  end
end
