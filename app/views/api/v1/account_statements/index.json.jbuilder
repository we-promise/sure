# frozen_string_literal: true

json.data do
  json.array! @statements, partial: "api/v1/account_statements/account_statement", as: :account_statement
end

json.meta do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
