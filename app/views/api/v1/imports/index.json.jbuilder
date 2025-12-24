json.data do
  json.array! @imports do |import|
    json.id import.id
    json.type import.type
    json.status import.status
    json.created_at import.created_at
    json.updated_at import.updated_at
    json.account_id import.account_id
    json.rows_count import.rows_count
    json.error import.error if import.error.present?
  end
end

json.meta do
  json.current_page @pagy.page
  json.next_page @pagy.next
  json.prev_page @pagy.prev
  json.total_pages @pagy.pages
  json.total_count @pagy.count
  json.per_page @per_page
end
