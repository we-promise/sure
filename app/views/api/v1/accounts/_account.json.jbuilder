# frozen_string_literal: true

balance_money = account.balance_money
cash_balance_money = account.cash_balance_money

json.id account.id
json.name account.name
json.balance balance_money.format
json.balance_cents((balance_money.amount * balance_money.currency.minor_unit_conversion).round(0).to_i)
json.cash_balance cash_balance_money.format
json.cash_balance_cents((cash_balance_money.amount * cash_balance_money.currency.minor_unit_conversion).round(0).to_i)
json.currency account.currency
json.classification account.classification
json.account_type account.accountable_type&.underscore
json.subtype account.subtype
json.status account.status
json.institution_name account.institution_name
json.institution_domain account.institution_domain
json.brazil_bank_id account.brazil_bank_id
json.brazil_bank_ispb account.brazil_bank&.ispb
json.brazil_bank_code account.brazil_bank&.code
json.brazil_bank_name account.brazil_bank&.short_name
json.brazil_account_kind account.brazil_account_kind
json.created_at account.created_at.iso8601
json.updated_at account.updated_at.iso8601
