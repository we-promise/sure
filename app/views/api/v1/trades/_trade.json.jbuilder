# frozen_string_literal: true

json.id trade.id
json.date trade.entry.date
json.amount trade.entry.amount_money.format
json.currency trade.currency
json.name trade.entry.name
json.notes trade.entry.notes
json.qty trade.qty
json.price trade.price_money.format
json.investment_activity_label trade.investment_activity_label

json.account do
  json.id trade.entry.account.id
  json.name trade.entry.account.name
  json.account_type trade.entry.account.accountable_type.underscore
end

if trade.security.present?
  json.security do
    json.id trade.security.id
    json.ticker trade.security.ticker
    json.name trade.security.name
  end
else
  json.security nil
end

if trade.category.present?
  json.category do
    json.id trade.category.id
    json.name trade.category.name
  end
else
  json.category nil
end

json.created_at trade.created_at.iso8601
json.updated_at trade.updated_at.iso8601
