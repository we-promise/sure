# frozen_string_literal: true

json.data @rules do |rule|
  json.partial! "api/v1/rules/rule", rule: rule
end

json.meta do
  json.current_page @pagy.page
  json.next_page @pagy.next
  json.prev_page @pagy.prev
  json.total_pages @pagy.pages
  json.total_count @pagy.count
  json.per_page @per_page
end
