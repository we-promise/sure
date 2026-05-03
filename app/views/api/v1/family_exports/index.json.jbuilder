# frozen_string_literal: true

json.data do
  json.array! @family_exports, partial: "api/v1/family_exports/family_export", as: :family_export
end

json.meta do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
