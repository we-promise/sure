# Filters for the trades the caller may already see, on their entry's account
# and date. See ScopedSearch.
class Trade::Search
  include ScopedSearch

  attribute :account_id, :string
  attribute :account_ids # an Array; ActiveModel ignores `array: true`
  attribute :start_date, :date
  attribute :end_date, :date

  def trades_scope
    relation = scope.with_entry
    relation = relation.where(entries: { account_id: }) unless account_id.nil?
    relation = relation.where(entries: { account_id: account_ids }) unless account_ids.nil?
    relation = relation.where(entries: { date: start_date.. }) unless start_date.nil?
    relation = relation.where(entries: { date: ..end_date }) unless end_date.nil?
    relation
  end
end
