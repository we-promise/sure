# frozen_string_literal: true

json.transaction_id @transaction.id
json.amount @entry.amount_money.format
json.currency @entry.currency
json.children @entry.child_entries.includes(:entryable, :account).order(:created_at) do |child|
  json.partial! "api/v1/transactions/transaction", transaction: child.entryable
end
