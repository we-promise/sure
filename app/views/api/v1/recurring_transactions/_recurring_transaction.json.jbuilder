# frozen_string_literal: true

json.id recurring_transaction.id
json.amount recurring_transaction.amount_money.format
money_to_minor_units = lambda do |money|
  (money.amount * money.currency.minor_unit_conversion).round(0).to_i if money
end
json.amount_cents money_to_minor_units.call(recurring_transaction.amount_money)
json.currency recurring_transaction.currency
json.expected_day_of_month recurring_transaction.expected_day_of_month
json.last_occurrence_date recurring_transaction.last_occurrence_date
json.next_expected_date recurring_transaction.next_expected_date
json.status recurring_transaction.status
json.occurrence_count recurring_transaction.occurrence_count
json.name recurring_transaction.name
json.manual recurring_transaction.manual
json.expected_amount_min recurring_transaction.expected_amount_min_money&.format
json.expected_amount_min_cents money_to_minor_units.call(recurring_transaction.expected_amount_min_money)
json.expected_amount_max recurring_transaction.expected_amount_max_money&.format
json.expected_amount_max_cents money_to_minor_units.call(recurring_transaction.expected_amount_max_money)
json.expected_amount_avg recurring_transaction.expected_amount_avg_money&.format
json.expected_amount_avg_cents money_to_minor_units.call(recurring_transaction.expected_amount_avg_money)
json.created_at recurring_transaction.created_at.iso8601
json.updated_at recurring_transaction.updated_at.iso8601

if recurring_transaction.account.present?
  json.account do
    json.id recurring_transaction.account.id
    json.name recurring_transaction.account.name
    json.account_type recurring_transaction.account.accountable_type&.underscore
  end
else
  json.account nil
end

if recurring_transaction.merchant.present?
  json.merchant do
    json.id recurring_transaction.merchant.id
    json.name recurring_transaction.merchant.name
  end
else
  json.merchant nil
end
