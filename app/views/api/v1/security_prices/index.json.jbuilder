# frozen_string_literal: true

json.security_prices @security_prices do |security_price|
  json.partial! "security_price", security_price: security_price
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
