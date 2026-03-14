# frozen_string_literal: true

json.merchants @merchants do |merchant|
  json.partial! "api/v1/merchants/merchant", merchant: merchant
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
