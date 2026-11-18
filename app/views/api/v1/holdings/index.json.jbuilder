# frozen_string_literal: true

lots = Holding.open_lots_for(@holdings.to_a)
json.holdings @holdings do |holding|
  json.partial! "holding", holding: holding, lots: lots[holding.id]
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
