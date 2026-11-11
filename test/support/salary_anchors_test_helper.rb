# Declares a salary series and records paydays against it the way the
# recurring matcher does, for tests of income-anchored budget months.
module SalaryAnchorsTestHelper
  def declare_salary(family, account: accounts(:depository), name: "ACME PAYROLL", amount: 3000)
    family.recurring_transactions.create!(
      account: account,
      name: name,
      amount: -amount,
      currency: "USD",
      expected_day_of_month: 27,
      last_occurrence_date: Date.current,
      next_expected_date: Date.current + 1.month,
      status: "active",
      bill_type: "income",
      manual: true
    )
  end

  def land_salary(series, date, state: "confirmed")
    entry = series.account.entries.create!(
      date: date,
      amount: series.amount,
      currency: series.currency,
      name: series.name,
      entryable: Transaction.new
    )
    occurrence = series.recurring_occurrences.find_or_create_by!(original_due_on: date) do |o|
      o.family = series.family
      o.due_on = date
      o.currency = series.currency
    end

    RecurringTransaction::Allocator.new(occurrence)
      .allocate_matched!(entry: entry, state: state, confidence: BigDecimal("0.9"), signals: {})
    entry
  end

  def anchor_months_to(family, series)
    family.update!(month_start_mode: "income", month_start_recurring_transaction: series)
  end
end
