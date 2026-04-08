# frozen_string_literal: true

json.transfers @transfers do |transfer|
  json.partial! "transfer", transfer: transfer
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
