
# Simulation of the loan balance calculation mismatch

def calculate_payment_date_for_term(first_payment_date, term_number, payment_period)
  return first_payment_date if term_number <= 1

  date = first_payment_date
  (term_number - 1).times do
    case payment_period
    when "weekly"
      date += 1.week
    when "bi_weekly"
      date += 2.weeks
    when "monthly"
      date += 1.month
    when "quarterly"
      date += 3.months
    when "yearly"
      date += 1.year
    end
  end
  date
end

def generate_payment_schedule(first_payment_date, total_term, payment_period, installment_cost)
  schedule = []
  date = first_payment_date

  total_term.times do |i|
    schedule << {
      payment_number: i + 1,
      date: date,
      amount: installment_cost
    }
    case payment_period
    when "weekly"
      date += 1.week
    when "bi_weekly"
      date += 2.weeks
    when "monthly"
      date += 1.month
    when "quarterly"
      date += 3.months
    when "yearly"
      date += 1.year
    end
  end

  schedule
end

def payments_scheduled_to_date(first_payment_date, total_term, payment_period, installment_cost)
  return 0 if Date.current < first_payment_date

  schedule = generate_payment_schedule(first_payment_date, total_term, payment_period, installment_cost)
  schedule.count { |payment| payment[:date] <= Date.current }
end

# Test case:
# Today is Jan 23, 2026
# User says they are on payment 5 of 10
# Payment day is 15
# Monthly period

# JS Logic for firstPaymentDate:
# getMostRecentPastDate(15) -> Jan 15, 2026
# subtractPeriods(Jan 15, 4, "monthly") -> Sep 15, 2025

first_payment_date = Date.new(2025, 9, 15)
current_term = 5
total_term = 10
payment_period = "monthly"
installment_cost = 1000

scheduled = payments_scheduled_to_date(first_payment_date, total_term, payment_period, installment_cost)

puts "Today: #{Date.current}"
puts "First payment date: #{first_payment_date}"
puts "Expected current term: #{current_term}"
puts "Actual scheduled payments: #{scheduled}"

if current_term != scheduled
  puts "MISMATCH FOUND!"
else
  puts "No mismatch for this case."
end

# Case 2: Today is Jan 23, payment day is 23
# getMostRecentPastDate(23) -> Jan 23, 2026
# subtractPeriods(Jan 23, 4, "monthly") -> Sep 23, 2025
first_payment_date_2 = Date.new(2025, 9, 23)
scheduled_2 = payments_scheduled_to_date(first_payment_date_2, total_term, payment_period, installment_cost)
puts "\nCase 2 (payment day is today):"
puts "First payment date: #{first_payment_date_2}"
puts "Expected current term: #{current_term}"
puts "Actual scheduled payments: #{scheduled_2}"

# Case 3: Today is Jan 23, payment day is 24
# getMostRecentPastDate(24) -> Dec 24, 2025
# subtractPeriods(Dec 24, 4, "monthly") -> Aug 24, 2025
first_payment_date_3 = Date.new(2025, 8, 24)
scheduled_3 = payments_scheduled_to_date(first_payment_date_3, total_term, payment_period, installment_cost)
puts "\nCase 3 (payment day is tomorrow):"
puts "First payment date: #{first_payment_date_3}"
puts "Expected current term: #{current_term}"
puts "Actual scheduled payments: #{scheduled_3}"

# Case 4: End of month edge case
# Today is Mar 30, payment day is 31
# getMostRecentPastDate(31) -> Feb 28 (non-leap)
# subtractPeriods(Feb 28, 1, "monthly") -> Jan 28?
# Ruby: Jan 31 + 1.month = Feb 28
# JS: Feb 28 minus 1 month = Jan 28 (because JS subtractMonths(Feb 28, 1) sets month to Jan, day stays 28)
# Wait, let's check JS subtractMonths again:
# If Jan 31 - 1 month:
# setMonth(0) -> Month is now 0 (Jan), Day is 31.
# originalDay (31) matches date.getDate() (31).
# So it stays Jan 31.
# But if Mar 31 - 1 month:
# setMonth(1) -> Feb 31 -> Rolls to Mar 3.
# date.getDate() (3) != originalDay (31).
# setDate(0) -> Sets to last day of Feb.

# So JS Mar 31 -> Feb 28/29.
# Ruby Mar 31 - 1.month -> Feb 28/29.
# They should match.
