# frozen_string_literal: true

json.recurring_transactions @recurring_transactions do |recurring_transaction|
  json.partial! "recurring_transaction", recurring_transaction: recurring_transaction
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
