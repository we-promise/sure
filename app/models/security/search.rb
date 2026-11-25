# Filters for the securities the caller may already see. Ticker and MIC match
# whatever their case. See ScopedSearch.
class Security::Search
  include ScopedSearch

  attribute :ticker, :string
  attribute :exchange_operating_mic, :string
  attribute :kind, :string
  attribute :offline, :boolean

  def securities_scope
    relation = scope
    relation = relation.where("LOWER(securities.ticker) = ?", ticker.downcase) unless ticker.nil?
    relation = relation.where(exchange_operating_mic: exchange_operating_mic.upcase) unless exchange_operating_mic.nil?
    relation = relation.where(kind:) unless kind.nil?
    relation = relation.where(offline:) unless offline.nil?
    relation
  end
end
