# frozen_string_literal: true

json.transaction_id @transaction.id
json.amount @entry.amount_money.format

# The formatted amount above rounds to the currency's display precision, but
# split! requires submitted children to sum to the stored decimal(19,4) value.
# A client replacing a split needs the exact figure, so expose it unrounded,
# alongside the minor-unit integer the transaction partial already uses.
json.amount_decimal @entry.amount.to_s
amount_money = @entry.amount_money
json.amount_cents (amount_money.amount * amount_money.currency.minor_unit_conversion).round(0).to_i.abs

json.currency @entry.currency
json.children @children do |child|
  json.partial! "api/v1/transactions/transaction", transaction: child

  # PATCH replaces every child, so a client editing one field has to send the
  # rest back unchanged. The transaction partial carries neither of these: its
  # amount is display-rounded, and it never emits the exclusion flag.
  json.amount_decimal child.entry.amount.to_s
  json.excluded child.entry.excluded
end
