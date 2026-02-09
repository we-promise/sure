# frozen_string_literal: true

json.holdings @holdings do |holding|
  json.partial! "holding", holding: holding
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
