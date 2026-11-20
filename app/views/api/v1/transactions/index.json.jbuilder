# frozen_string_literal: true

refund_details = Transaction::RefundDetails.new(transactions: @transactions, user: current_resource_owner)

json.transactions @transactions do |transaction|
  json.partial! "transaction", transaction: transaction, refund_details: refund_details, split_parent_ids: @split_parent_entry_ids
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
