# frozen_string_literal: true

json.exchange_rates @exchange_rates do |exchange_rate|
  json.partial! "exchange_rate", exchange_rate: exchange_rate
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
