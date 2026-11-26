module AutoMatchesHelper
  # A first sync can pull years of history, so pending matches are often
  # old. "Oct 30" alone reads as this October; the date gains the year
  # whenever it falls in another one. Same rule as BillsHelper#bills_upcoming_date.
  def auto_match_date(date)
    l(date, format: date.year == Date.current.year ? :short : :short_with_year)
  end

  # The auto matcher pairs legs that are a few days apart, but the row shows
  # one date (the inflow's, Transfer#date). The gap helps tell a same-day
  # move from a coincidental amount match. Nil when the legs share a date
  # or one is missing.
  def auto_match_days_apart(transfer)
    outflow_date = transfer.outflow_transaction&.entry&.date
    inflow_date = transfer.inflow_transaction&.entry&.date
    return if outflow_date.nil? || inflow_date.nil?

    days = (inflow_date - outflow_date).to_i.abs
    days.zero? ? nil : days
  end
end
