# Resolves the family's financial month around any date.
#
# Fixed-day mode: a month starts on `month_start_day` (the 1st by default).
#
# Income mode: a month starts on the day the declared salary series actually
# landed and ends the day before the next one. Dates before the first salary
# fall back to fixed-day months, clipped so the last one ends the day before
# that salary. After the latest salary the months are projected one calendar
# month at a time until the next salary lands and replaces the projection.
class Family::MonthPeriods
  # A second matched inflow this close to the previous anchor (a split or
  # corrected paycheck) does not start a new month.
  DEFAULT_MIN_GAP_DAYS = 20

  attr_reader :family, :min_gap_days

  def initialize(family, min_gap_days: DEFAULT_MIN_GAP_DAYS)
    @family = family
    @min_gap_days = min_gap_days
  end

  # [start_date, end_date] of the month containing `date`.
  def bounds_for(date)
    return fixed_bounds_for(date) if anchors.empty?

    first_anchor = anchors.first
    if date < first_anchor
      start_date, end_date = fixed_bounds_for(date)
      return [ start_date, [ end_date, first_anchor - 1.day ].min ]
    end

    index = anchors.rindex { |anchor| anchor <= date }
    next_anchor = anchors[index + 1]
    return [ anchors[index], next_anchor - 1.day ] if next_anchor

    projected_bounds_for(date, anchors.last)
  end

  def start_for(date)
    bounds_for(date).first
  end

  def end_for(date)
    bounds_for(date).last
  end

  # The first month start inside the calendar month of `date`, or nil when a
  # single month spans all of it (a salary on Jan 31 and the next on Mar 2).
  def first_start_in_month(date)
    month_begin = date.beginning_of_month
    start_date, end_date = bounds_for(month_begin)
    return start_date if start_date == month_begin

    next_start = end_date + 1.day
    next_start if next_start <= month_begin.end_of_month
  end

  # Dates the declared salary landed, oldest first, with near-duplicates
  # inside the minimum gap dropped.
  def anchors
    @anchors ||= begin
      series = family.month_start_series
      series ? dedupe(salary_dates(series)) : []
    end
  end

  private
    def fixed_bounds_for(date)
      day = family.month_start_day
      start_date = if date.day >= day
        Date.new(date.year, date.month, day)
      else
        previous_month = date - 1.month
        Date.new(previous_month.year, previous_month.month, day)
      end

      [ start_date, start_date + 1.month - 1.day ]
    end

    # Counted from the anchor each time rather than chained, so a salary on
    # the 31st does not drift to the 28th after February.
    def projected_bounds_for(date, anchor)
      months = (date.year * 12 + date.month) - (anchor.year * 12 + anchor.month)
      months -= 1 if anchor.advance(months: months) > date

      [ anchor.advance(months: months), anchor.advance(months: months + 1) - 1.day ]
    end

    def salary_dates(series)
      Entry
        .joins("INNER JOIN recurring_allocations ON recurring_allocations.entry_id = entries.id")
        .joins("INNER JOIN recurring_occurrences ON recurring_occurrences.id = recurring_allocations.recurring_occurrence_id")
        .where(recurring_occurrences: { recurring_transaction_id: series.id })
        .where(recurring_allocations: { state: "confirmed" })
        .distinct
        .order(:date)
        .pluck(:date)
    end

    def dedupe(dates)
      dates.each_with_object([]) do |date, kept|
        kept << date if kept.empty? || (date - kept.last).to_i >= min_gap_days
      end
    end
end
