json.id @account.id
json.name @account.name
json.balance @account.balance_money.format
json.currency @account.currency
json.classification @account.classification
json.account_type @account.accountable_type.underscore
json.created_at @account.created_at.iso8601
json.updated_at @account.updated_at.iso8601
