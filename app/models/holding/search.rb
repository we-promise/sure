# Filters for the holdings the caller may already see. See ScopedSearch.
class Holding::Search
  include ScopedSearch

  attribute :account_id, :string
  attribute :account_ids # an Array; ActiveModel ignores `array: true`
  attribute :security_id, :string
  attribute :date, :date
  attribute :start_date, :date
  attribute :end_date, :date

  def holdings_scope
    relation = scope
    relation = relation.where(account_id:) unless account_id.nil?
    relation = relation.where(account_id: account_ids) unless account_ids.nil?
    relation = relation.where(security_id:) unless security_id.nil?
    relation = relation.where(date:) unless date.nil?
    within_range(relation, :date, start_date, end_date)
  end
end
