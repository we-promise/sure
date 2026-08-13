module BillsHelper
  # Leads with the relative distance, which is what tells you whether to act, and
  # keeps the absolute date alongside it for anything further out than a few days.
  #
  # Relative wording is also the safer default: the app runs in UTC while users do
  # not, so a bare calendar date can read as off-by-one for part of every day.
  def bills_due_label(bill)
    days = (bill.next_due_date - Date.current).to_i
    date = l(bill.next_due_date, format: :short)

    if days.negative?
      t("bills.due_label.overdue", count: days.abs, date: date)
    elsif days.zero?
      t("bills.due_label.today")
    else
      t("bills.due_label.upcoming", count: days, date: date)
    end
  end
end
