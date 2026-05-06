# frozen_string_literal: true

json.data do
  json.array! @syncs, partial: "api/v1/syncs/sync", as: :sync
end

json.meta do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
