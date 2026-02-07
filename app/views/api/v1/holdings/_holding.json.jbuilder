# frozen_string_literal: true

json.id holding.id
json.date holding.date
json.qty holding.qty
json.price Money.new(holding.price, holding.currency).format
json.amount holding.amount_money.format
json.currency holding.currency
json.cost_basis_source holding.cost_basis_source

json.account do
  json.id holding.account.id
  json.name holding.account.name
  json.account_type holding.account.accountable_type.underscore
end

json.security do
  json.id holding.security.id
  json.ticker holding.security.ticker
  json.name holding.security.name
end

avg = holding.avg_cost
json.avg_cost avg ? avg.format : nil

json.created_at holding.created_at.iso8601
json.updated_at holding.updated_at.iso8601
