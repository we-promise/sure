# frozen_string_literal: true

money_to_minor_units = lambda do |money|
  (money.amount * money.currency.minor_unit_conversion).round(0).to_i if money
end
include_derived_amounts = local_assigns.fetch(:include_derived_amounts, true)

json.id budget_category.id
json.budget_id budget_category.budget_id
json.currency budget_category.currency
json.subcategory budget_category.subcategory?
json.inherits_parent_budget budget_category.inherits_parent_budget?

json.budgeted_spending budget_category.budgeted_spending_money.format
json.budgeted_spending_cents money_to_minor_units.call(budget_category.budgeted_spending_money)
json.display_budgeted_spending Money.new(budget_category.display_budgeted_spending, budget_category.currency).format
json.display_budgeted_spending_cents money_to_minor_units.call(Money.new(budget_category.display_budgeted_spending, budget_category.currency))
if include_derived_amounts
  json.actual_spending budget_category.actual_spending_money.format
  json.actual_spending_cents money_to_minor_units.call(budget_category.actual_spending_money)
  json.available_to_spend budget_category.available_to_spend_money.format
  json.available_to_spend_cents money_to_minor_units.call(budget_category.available_to_spend_money)
end

json.category do
  json.id budget_category.category.id
  json.name budget_category.category.name
  json.color budget_category.category.color
  json.lucide_icon budget_category.category.lucide_icon
  json.parent_id budget_category.category.parent_id
end

json.created_at budget_category.created_at.iso8601
json.updated_at budget_category.updated_at.iso8601
