# frozen_string_literal: true

json.accounts @accounts do |account|
  json.partial! "account", account: account
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
