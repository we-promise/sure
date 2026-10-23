# frozen_string_literal: true

refund_details = Transaction::RefundDetails.new(transactions: [ @transaction ], user: current_resource_owner)

json.partial! "api/v1/transactions/transaction", transaction: @transaction, refund_details: refund_details
