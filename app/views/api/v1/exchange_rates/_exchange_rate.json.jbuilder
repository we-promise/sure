# frozen_string_literal: true

json.id exchange_rate.id
json.from_currency exchange_rate.from_currency
json.to_currency exchange_rate.to_currency
json.date exchange_rate.date
json.rate exchange_rate.rate.to_s

json.created_at exchange_rate.created_at.iso8601
json.updated_at exchange_rate.updated_at.iso8601
