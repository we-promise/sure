# frozen_string_literal: true

json.balances @balances do |balance|
  json.partial! "balance", balance: balance
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
