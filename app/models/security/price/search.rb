# Filters for the prices of the securities the caller may already see. The
# currency matches whatever its case. See ScopedSearch.
class Security::Price::Search
  include ScopedSearch

  attribute :security_id, :string
  attribute :currency, :string
  attribute :start_date, :date
  attribute :end_date, :date
  attribute :provisional, :boolean
  attribute :carried_forward, :boolean

  def security_prices_scope
    relation = scope
    relation = relation.where(security_id:) unless security_id.nil?
    relation = relation.where(currency: currency.upcase) unless currency.nil?
    relation = within_range(relation, :date, start_date, end_date)
    relation = relation.where(provisional:) unless provisional.nil?
    relation = relation.where(carried_forward:) unless carried_forward.nil?
    relation
  end
end
