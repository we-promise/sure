# frozen_string_literal: true

json.valuations @entries do |entry|
  json.partial! "valuation", valuation: entry.entryable, entry: entry
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
