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

  # Which account the charge lands on. Sure already knows this and has never shown it,
  # and it is exactly what you check when deciding whether a bill is covered.
  def bills_paid_from_label(bill)
    return "" if bill.account.blank?

    " · #{t('bills.paid_from', account: bill.account.name)}"
  end

  # The occurrence-level twin of bills_due_label: relative-first, snooze-aware.
  def occurrence_due_label(occurrence)
    due = occurrence.effective_due_on
    days = (due - Date.current).to_i
    date = l(due, format: :short)

    if occurrence.snoozed_until.present? && occurrence.snoozed_until > occurrence.due_on && days.positive?
      t("bills.due_label.snoozed", date: date)
    elsif days.negative?
      t("bills.due_label.overdue", count: days.abs, date: date)
    elsif days.zero?
      t("bills.due_label.today")
    else
      t("bills.due_label.upcoming", count: days, date: date)
    end
  end

  # An amount whose expectation is derived (average strategy, or an observed
  # variance band) is shown as approximate; a fixed declared amount never is.
  def occurrence_amount_estimated?(occurrence)
    return false if occurrence.expected_amount.present?

    series = occurrence.recurring_transaction
    !series.amount_fixed? || series.has_amount_variance?
  end
end
