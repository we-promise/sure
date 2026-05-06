# frozen_string_literal: true

money_to_minor_units = lambda do |money|
  (money.amount * money.currency.minor_unit_conversion).round(0).to_i if money
end

include_derived_amounts = local_assigns.fetch(:include_derived_amounts, true)

json.id budget.id
json.start_date budget.start_date
json.end_date budget.end_date
json.name budget.name
json.currency budget.currency
json.initialized budget.initialized?
json.current budget.current?

json.budgeted_spending budget.budgeted_spending_money&.format
json.budgeted_spending_cents money_to_minor_units.call(budget.budgeted_spending_money)
json.expected_income budget.expected_income_money&.format
json.expected_income_cents money_to_minor_units.call(budget.expected_income_money)
json.allocated_spending budget.allocated_spending_money.format
json.allocated_spending_cents money_to_minor_units.call(budget.allocated_spending_money)

if include_derived_amounts
  json.actual_spending budget.actual_spending_money.format
  json.actual_spending_cents money_to_minor_units.call(budget.actual_spending_money)
  json.actual_income budget.actual_income_money.format
  json.actual_income_cents money_to_minor_units.call(budget.actual_income_money)
  json.available_to_spend budget.available_to_spend_money.format
  json.available_to_spend_cents money_to_minor_units.call(budget.available_to_spend_money)
  json.available_to_allocate budget.available_to_allocate_money.format
  json.available_to_allocate_cents money_to_minor_units.call(budget.available_to_allocate_money)
end

json.created_at budget.created_at.iso8601
json.updated_at budget.updated_at.iso8601
