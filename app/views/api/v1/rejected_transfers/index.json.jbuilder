# frozen_string_literal: true

json.rejected_transfers @rejected_transfers do |rejected_transfer|
  json.partial! "rejected_transfer", rejected_transfer: rejected_transfer
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
