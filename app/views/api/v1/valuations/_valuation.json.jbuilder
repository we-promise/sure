# frozen_string_literal: true

entry = local_assigns[:entry] || valuation.entry

json.id entry.id
json.date entry.date
json.amount entry.amount_money.format
json.currency entry.currency
json.notes entry.notes
json.kind valuation.kind

# Account information
json.account do
  json.id entry.account.id
  json.name entry.account.name
  json.account_type entry.account.accountable_type.underscore
end

# Additional metadata
json.created_at valuation.created_at.iso8601
json.updated_at valuation.updated_at.iso8601
