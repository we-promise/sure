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
json.payment_url recurring_transaction.payment_url
json.autopay recurring_transaction.autopay
json.notes recurring_transaction.notes
json.expected_amount_min recurring_transaction.expected_amount_min_money&.format
json.expected_amount_min_cents money_to_minor_units.call(recurring_transaction.expected_amount_min_money)
json.expected_amount_max recurring_transaction.expected_amount_max_money&.format
json.expected_amount_max_cents money_to_minor_units.call(recurring_transaction.expected_amount_max_money)
json.expected_amount_avg recurring_transaction.expected_amount_avg_money&.format
json.expected_amount_avg_cents money_to_minor_units.call(recurring_transaction.expected_amount_avg_money)
json.bill_type recurring_transaction.bill_type
json.category_id recurring_transaction.category_id
json.anchor_date recurring_transaction.anchor_date
json.weekend_adjust recurring_transaction.weekend_adjust
json.end_mode recurring_transaction.end_mode
json.end_on recurring_transaction.end_on
json.end_after_count recurring_transaction.end_after_count
json.renews_on recurring_transaction.renews_on
json.trial_ends_on recurring_transaction.trial_ends_on
json.cancelled_on recurring_transaction.cancelled_on
json.recurrence_rules recurring_transaction.recurrence_rules do |rule|
  json.frequency rule.frequency
  json.interval rule.interval
  json.day_of_month rule.day_of_month
  json.weekday rule.weekday
  json.weekday_ordinal rule.weekday_ordinal
  json.month_of_year rule.month_of_year
end
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
