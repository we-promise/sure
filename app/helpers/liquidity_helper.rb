# View helpers for the availability overview (BalanceSheet::LiquidityOverview)
# on the dashboard and in reports.
module LiquidityHelper
  LEVEL_BAR_CLASSES = {
    "immediate" => "bg-success",
    "short_term" => "bg-success/50",
    "locked" => "bg-warning",
    "long_term" => "bg-subdued"
  }.freeze

  def liquidity_level_bar_class(level)
    LEVEL_BAR_CLASSES.fetch(level, "bg-subdued")
  end

  def liquidity_bucket_label(key)
    t("liquidity.buckets.#{key}")
  end

  # "in 42 days" / "today" for a release; nil for an undated one.
  def liquidity_release_remaining(release)
    return nil if release.days.nil?
    return t("liquidity.remaining.today") if release.days.zero?

    t("liquidity.remaining.days", count: release.days)
  end

  LiquidityReleaseTableRow = Data.define(:release, :year, :amount) do
    def total? = release.nil?
  end

  # The release table's rows: the releases of each year followed by that
  # year's total, flat, so DS::Table renders them as one list.
  def liquidity_release_table_rows(overview)
    totals = overview.releases_by_year
    overview.releases.group_by { |release| release.date.year }.flat_map do |year, releases|
      releases.map { |release| LiquidityReleaseTableRow.new(release: release, year: year, amount: release.amount) } +
        [ LiquidityReleaseTableRow.new(release: nil, year: year, amount: totals[year]) ]
    end
  end

  # Width (percent) of a bar relative to the largest value in the set.
  def liquidity_bar_width(amount, max)
    return 0 unless max.positive? && amount.positive?

    [ (amount / max * 100).round(1), 2 ].max
  end
end
