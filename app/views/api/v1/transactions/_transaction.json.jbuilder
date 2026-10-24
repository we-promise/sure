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

# `amount` and `amount_cents` are both rounded to the currency's display
# precision, but entries store decimal(19,4). Expose the stored value
# unrounded, as a locale-independent string in the entry's own sign
# convention (positive = outflow, negative = inflow), the same field split
# show returns, so a client can build a split that sums exactly. "F" keeps
# it fixed-point (12.3456, never 0.123456e2) without relying on
# ActiveSupport's BigDecimal#to_s default.
json.amount_decimal transaction.entry.amount.to_s("F")

json.currency transaction.entry.currency
json.name transaction.entry.name
json.notes transaction.entry.notes
json.external_id transaction.entry.external_id
json.source transaction.entry.source
json.user_modified transaction.entry.user_modified
json.classification transaction.entry.classification

# How budgets and reports treat the row: loan_payment counts as an expense
# whatever the amount's sign; investment_contribution does too unless the
# family turned off investment_contributions_as_spending, in which case it is
# reported as invested and left out (Family#analytics_excluded_kinds); and
# Transaction::BUDGET_EXCLUDED_KINDS are left out entirely.
json.kind transaction.kind

# Excluded entries are left out of budget and report totals, and splitting
# marks the parent excluded. A split parent's amount is carried by its
# children, so a client summing a list should skip the parent. entries.excluded
# is nullable, so the predicate keeps the field a boolean. Callers that render
# many rows pass split_parent_ids (the set of entry ids with children) so
# split_parent costs no query per row; a single row falls back to an EXISTS.
json.excluded transaction.entry.excluded?
split_parent_ids = local_assigns[:split_parent_ids]
json.split_parent split_parent_ids ? split_parent_ids.include?(transaction.entry.id) : transaction.entry.split_parent?

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
transfer = transaction.transfer
if transfer.present?
  json.transfer do
    json.id transfer.id

    # Other transaction in the transfer
    if transfer.inflow_transaction_id == transaction.id
      inflow_transaction = transaction
      other_transaction = transfer.outflow_transaction
    else
      inflow_transaction = transfer.inflow_transaction
      # When rendering the outflow, the inflow is the counterparty transaction.
      other_transaction = inflow_transaction
    end

    json.amount inflow_transaction.entry.amount_money.abs.format
    json.currency inflow_transaction.entry.currency

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
