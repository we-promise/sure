# frozen_string_literal: true

json.id security_price.id
json.date security_price.date
json.price Money.new(security_price.price, security_price.currency).format
# At least 4 decimals as before, and up to the column's 10 for low-value assets.
# Formatted from the BigDecimal: format("%f") goes through Float and rounds.
whole, fraction = security_price.price.to_d.round(10).to_s("F").split(".")
json.price_amount "#{whole}.#{fraction.to_s.ljust(4, "0")}"
json.currency security_price.currency
json.provisional security_price.provisional

json.security do
  json.id security_price.security.id
  json.ticker security_price.security.ticker
  json.name security_price.security.name
  json.exchange_operating_mic security_price.security.exchange_operating_mic
end

json.created_at security_price.created_at.iso8601
json.updated_at security_price.updated_at.iso8601
