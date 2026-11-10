# frozen_string_literal: true

json.id account_statement.id
json.filename account_statement.filename
json.content_type account_statement.content_type
json.byte_size account_statement.byte_size
json.content_sha256 account_statement.content_sha256
json.review_status account_statement.review_status
json.period_start_on account_statement.period_start_on&.iso8601
json.period_end_on account_statement.period_end_on&.iso8601
json.currency account_statement.statement_currency
json.opening_balance account_statement.opening_balance&.to_s
json.closing_balance account_statement.closing_balance&.to_s
json.institution_name_hint account_statement.institution_name_hint
json.account_last4_hint account_statement.account_last4_hint

if account_statement.account
  json.account do
    json.id account_statement.account.id
    json.name account_statement.account.name
    json.currency account_statement.account.currency
  end
else
  json.account nil
end

# Only reveal a suggestion the caller could see on its own.
suggested = account_statement.suggested_account
if suggested && accessible_account_ids.include?(suggested.id)
  json.suggested_account do
    json.id suggested.id
    json.name suggested.name
    json.currency suggested.currency
  end
  json.match_confidence account_statement.match_confidence&.to_f
else
  json.suggested_account nil
  json.match_confidence nil
end

json.created_at account_statement.created_at.iso8601
json.updated_at account_statement.updated_at.iso8601
