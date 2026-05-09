# frozen_string_literal: true

json.id transfer.id
json.status transfer.status
json.date transfer.date
json.amount transfer.amount_abs.format
json.amount_cents money_to_minor_units(transfer.amount_abs)
json.currency transfer.inflow_transaction.entry.currency
json.transfer_type transfer.transfer_type
json.notes transfer.notes

json.inflow_transaction do
  json.partial! "api/v1/transfers/transaction_side", transaction: transfer.inflow_transaction
end

json.outflow_transaction do
  json.partial! "api/v1/transfers/transaction_side", transaction: transfer.outflow_transaction
end

json.created_at transfer.created_at.iso8601
json.updated_at transfer.updated_at.iso8601
