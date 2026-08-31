json.loan do
  json.id loan.id
  json.account_id loan.account.id
  json.name loan.account.name
  json.rate_type loan.rate_type
  json.interest_rate loan.interest_rate
  json.term_months loan.term_months
  json.original_balance loan.original_balance.to_s
  json.currency loan.account.currency
end

json.schedule do
  json.monthly_payment schedule.monthly_payment.to_s
  json.total_interest schedule.total_interest.to_s
  json.total_cost schedule.total_cost.to_s
  json.payoff_date schedule.payoff_date
  json.payment_count schedule.payment_count
end

json.pagination do
  json.limit limit
  json.offset offset
  json.total_count total_count
end

json.payments do
  json.array! payments do |payment|
    json.payment_number payment.payment_number
    json.payment_date payment.payment_date
    json.payment_amount payment.payment_amount
    json.principal_payment payment.principal_payment
    json.interest_payment payment.interest_payment
    json.beginning_balance payment.beginning_balance
    json.ending_balance payment.ending_balance
    json.interest_rate payment.interest_rate
  end
end
