# Net totals per category for each month or year in a report period, for the
# Reports category trend chart. A value is expense minus income booked to the
# category in the bucket, the rule IncomeStatement::SpendingComparison and the
# Sankeys use, so a refund lowers its category instead of plotting as more
# spending. A bucket with more refunds than purchases plots below zero.
#
# Totals come from the user-scoped IncomeStatement, so pending transactions,
# exclusions, transfers, tax-advantaged accounts and exchange rates follow the
# rest of Reports. The selection scopes only this chart.
class Reports::CategoryTrend
  GRANULARITIES = %w[month year].freeze

  attr_reader :granularity

  def initialize(statement, period:, selection:, granularity:)
    @statement = statement
    @period = period
    @selection = selection
    @granularity = GRANULARITIES.include?(granularity.to_s) ? granularity.to_s : "month"
  end

  def currency
    statement.family.currency
  end

  # One series per selected group, largest activity first. A parent total
  # already includes its subcategories, and the selection drops a child when
  # its parent is selected, so each value sums once. The name breaks ties, so
  # the legend order does not move between requests.
  def series
    @series ||= selection.group_values.filter_map { |value| series_for(value) }
      .sort_by { |entry| [ -entry[:values].sum { |point| point[:value].abs }, entry[:name] ] }
  end

  # Chart payload. Every series has one value per bucket.
  def as_json(*)
    { granularity: granularity, currency: currency, series: series }
  end

  private
    attr_reader :statement, :period, :selection

    def series_for(value)
      category = category_for(value)
      return nil unless category

      {
        name: category.name_with_parent,
        color: category.color.presence || Category::UNCATEGORIZED_COLOR,
        values: values_for(value)
      }
    end

    def category_for(value)
      return Category.uncategorized if value == Reports::CategorySelection::UNCATEGORIZED

      statement.family.categories.find_by(id: value)
    end

    def values_for(value)
      nets = net_by_key
      key = key_for(value)

      bucket_starts.map do |start|
        {
          date: start.iso8601,
          label: bucket_label(start),
          short_label: bucket_short_label(start),
          value: (nets.dig(key, start) || 0).to_f
        }
      end
    end

    # { category key => { bucket start => expense - income } } for the period.
    def net_by_key
      @net_by_key ||= bucket_starts.each_with_object({}) do |start, nets|
        bucket = bucket_period(start)
        add_totals(nets, start, statement.expense_totals(period: bucket).category_totals, 1)
        add_totals(nets, start, statement.income_totals(period: bucket).category_totals, -1)
      end
    end

    def add_totals(nets, start, category_totals, sign)
      category_totals.each do |category_total|
        next if category_total.total.zero?

        key = key_for_category(category_total.category)
        (nets[key] ||= {})[start] = (nets[key][start] || 0) + sign * category_total.total
      end
    end

    def bucket_starts
      @bucket_starts ||= begin
        starts = []
        cursor = bucket_start(period.start_date)
        last = bucket_start(period.end_date)

        while cursor <= last
          starts << cursor
          cursor = granularity == "year" ? cursor.next_year : cursor.next_month
        end

        starts
      end
    end

    def bucket_start(date)
      granularity == "year" ? date.to_date.beginning_of_year : date.to_date.beginning_of_month
    end

    # Clamp each bucket to the report period, so a custom range counts only
    # its own days.
    def bucket_period(start)
      finish = granularity == "year" ? start.end_of_year : start.end_of_month

      Period.custom(
        start_date: [ start, period.start_date ].max,
        end_date: [ finish, period.end_date ].min
      )
    end

    def bucket_label(start)
      granularity == "year" ? start.year.to_s : I18n.l(start, format: :short_month_year)
    end

    def bucket_short_label(start)
      granularity == "year" ? start.year.to_s : I18n.l(start, format: "%b")
    end

    def key_for(value)
      return :uncategorized if value == Reports::CategorySelection::UNCATEGORIZED

      value.to_s
    end

    def key_for_category(category)
      return :uncategorized if category.uncategorized?
      return :other_investments if category.other_investments?

      category.id.to_s
    end
end
