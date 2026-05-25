# frozen_string_literal: true

json.id transaction.id
json.date transaction.entry.date
json.amount transaction.entry.amount_money.format

# Agent/automation-friendly numeric fields (avoid localized parsing and clarify sign)
# `amount` in v1 is a localized string and may follow an accounting sign convention.
# Expose minor units (cents) as integers to make the API agent-friendly.
# Uses currency.minor_unit_conversion (e.g. 100 for USD/EUR, 1 for JPY, 1000 for KWD).
amount_money = transaction.entry.amount_money
conversion_factor = amount_money.currency.minor_unit_conversion
amount_cents = (amount_money.amount * conversion_factor).round(0).to_i.abs
json.amount_cents amount_cents
json.signed_amount_cents(transaction.entry.classification == "income" ? amount_cents : -amount_cents)

json.currency transaction.entry.currency
json.name transaction.entry.name
json.notes transaction.entry.notes
json.external_id transaction.entry.external_id
json.source transaction.entry.source
json.classification transaction.entry.classification

# Account information
json.account do
  json.id transaction.entry.account.id
  json.name transaction.entry.account.name
  json.account_type transaction.entry.account.accountable_type.underscore
end

# Category information
if transaction.category.present?
  json.category do
    json.id transaction.category.id
    json.name transaction.category.name
    json.color transaction.category.color
    json.icon transaction.category.lucide_icon
  end
else
  json.category nil
end

# Merchant information
if transaction.merchant.present?
  json.merchant do
    json.id transaction.merchant.id
    json.name transaction.merchant.name
  end
else
  json.merchant nil
end

# Tags
json.tags transaction.tags do |tag|
  json.id tag.id
  json.name tag.name
  json.color tag.color
end

# Transfer information (if this transaction is part of a transfer)
if transaction.transfer.present?
  json.transfer do
    transfer = transaction.transfer
    is_inflow = transfer.inflow_transaction_id == transaction.id
    json.id transfer.id
    amount_abs = is_inflow ? transaction.entry.amount_money.abs : transfer.amount_abs
    json.amount amount_abs.format

    inflow_currency = if is_inflow
      transaction.entry.currency
    else
      transfer.inflow_transaction.entry.currency
    end
    json.currency inflow_currency

    # Other transaction in the transfer
    other_transaction = if is_inflow
      transfer.outflow_transaction
    else
      transfer.inflow_transaction
    end

    if other_transaction.present?
      json.other_account do
        json.id other_transaction.entry.account.id
        json.name other_transaction.entry.account.name
        json.account_type other_transaction.entry.account.accountable_type.underscore
      end
    end
  end
else
  json.transfer nil
end

# Additional metadata
json.created_at transaction.created_at.iso8601
json.updated_at transaction.updated_at.iso8601
