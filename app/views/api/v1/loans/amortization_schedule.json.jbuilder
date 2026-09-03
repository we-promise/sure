json.loan do
  json.id loan.id
  json.account_id loan.account.id
  json.name loan.account.name
  json.rate_type loan.rate_type
  json.interest_rate loan.interest_rate.to_s
  json.term_months loan.term_months
  json.original_balance loan.original_balance.to_s
  json.currency loan.account.currency
  json.next_rate_change_date loan.next_rate_change_date
end

# Summary fields are derived from the persisted amortizations table, not the
# in-memory calculator -- a "current" response should cost roughly one
# indexed lookup plus a couple of aggregate queries bounded by the loan's
# term, never a full re-run of the amortization math.
first_payment = total_count.positive? ? loan.amortizations.ordered.first : nil
last_payment = total_count.positive? ? loan.amortizations.ordered.last : nil
total_interest = total_count.positive? ? loan.amortizations.sum(:interest_payment) : nil

json.schedule do
  json.status status
  json.monthly_payment first_payment&.payment_amount&.to_s
  json.total_interest total_interest&.to_s
  json.total_cost total_interest ? (loan.original_balance.amount + total_interest).to_s : nil
  json.payoff_date last_payment&.payment_date
  json.payment_count total_count
  json.has_rate_changes loan.rate_type == "variable" && loan.variable_rate_schedule.present?
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
    json.payment_amount payment.payment_amount.to_s
    json.principal_payment payment.principal_payment.to_s
    json.interest_payment payment.interest_payment.to_s
    json.beginning_balance payment.beginning_balance.to_s
    json.ending_balance payment.ending_balance.to_s
    json.interest_rate payment.interest_rate.to_s
  end
end
