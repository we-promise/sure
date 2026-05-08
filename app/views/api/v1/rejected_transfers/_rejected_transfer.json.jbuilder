# frozen_string_literal: true

json.id rejected_transfer.id

json.inflow_transaction do
  json.partial! "api/v1/transfers/transaction_side", transaction: rejected_transfer.inflow_transaction
end

json.outflow_transaction do
  json.partial! "api/v1/transfers/transaction_side", transaction: rejected_transfer.outflow_transaction
end

json.created_at rejected_transfer.created_at.iso8601
json.updated_at rejected_transfer.updated_at.iso8601
