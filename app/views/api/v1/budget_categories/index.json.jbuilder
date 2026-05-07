# frozen_string_literal: true

json.budget_categories @budget_categories do |budget_category|
  json.partial! "budget_category", budget_category: budget_category, include_derived_amounts: false
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
