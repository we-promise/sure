# frozen_string_literal: true

json.id transfer.id
json.status transfer.status
json.date transfer.date&.iso8601
json.amount transfer.amount_abs&.format
json.currency transfer.inflow_transaction.entry.currency
json.name transfer.name
json.transfer_type transfer.transfer_type
json.notes transfer.notes

# Source account (outflow side)
if transfer.from_account.present?
  json.from_account do
    json.id transfer.from_account.id
    json.name transfer.from_account.name
    json.account_type transfer.from_account.accountable_type.underscore
  end
else
  json.from_account nil
end

# Destination account (inflow side)
if transfer.to_account.present?
  json.to_account do
    json.id transfer.to_account.id
    json.name transfer.to_account.name
    json.account_type transfer.to_account.accountable_type.underscore
  end
else
  json.to_account nil
end

# Inflow transaction details
json.inflow_transaction do
  json.id transfer.inflow_transaction.id
  json.entry_id transfer.inflow_transaction.entry.id
  json.amount transfer.inflow_transaction.entry.amount_money.format
  json.currency transfer.inflow_transaction.entry.currency
end

# Outflow transaction details
json.outflow_transaction do
  json.id transfer.outflow_transaction.id
  json.entry_id transfer.outflow_transaction.entry.id
  json.amount transfer.outflow_transaction.entry.amount_money.format
  json.currency transfer.outflow_transaction.entry.currency
end

# Category (only applicable for loan payments)
if transfer.outflow_transaction.category.present?
  json.category do
    json.id transfer.outflow_transaction.category.id
    json.name transfer.outflow_transaction.category.name
  end
else
  json.category nil
end

json.created_at transfer.created_at.iso8601
json.updated_at transfer.updated_at.iso8601
