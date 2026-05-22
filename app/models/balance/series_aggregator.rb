class Balance::SeriesAggregator
  attr_reader :series_list, :favorable_direction, :currency, :align_to_common_start

  def initialize(series_list:, currency:, favorable_direction:, align_to_common_start: false)
    @series_list = Array(series_list).compact
    @currency = currency
    @favorable_direction = favorable_direction
    @align_to_common_start = align_to_common_start
  end

  def aggregate
    return empty_series if normalized_series_list.empty?

    values_by_date = normalized_series_list.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |series, hash|
      series.values.each do |value|
        hash[value.date] << value
      end
    end

    dates = values_by_date.keys.sort
    return empty_series if dates.empty?

    previous_value = nil
    values = dates.map do |date|
      current_value = Money.new(
        values_by_date[date].sum { |value| value.value.amount },
        currency
      )

      series_value = Series::Value.new(
        date: date,
        date_formatted: I18n.l(date, format: :long),
        value: current_value,
        trend: Trend.new(
          current: current_value,
          previous: previous_value,
          favorable_direction: favorable_direction
        )
      )

      previous_value = current_value
      series_value
    end

    Series.new(
      start_date: values.first.date,
      end_date: values.last.date,
      interval: normalized_series_list.first.interval,
      values: values,
      favorable_direction: favorable_direction
    )
  end

  private
    def normalized_series_list
      @normalized_series_list ||= begin
        return series_list unless align_to_common_start

        common_start_date = series_list.map(&:start_date).compact.max
        return series_list if common_start_date.blank?

        series_list.filter_map do |series|
          trimmed_values = series.values.select { |value| value.date >= common_start_date }
          next if trimmed_values.blank?

          Series.new(
            start_date: trimmed_values.first.date,
            end_date: trimmed_values.last.date,
            interval: series.interval,
            values: trimmed_values,
            favorable_direction: series.favorable_direction
          )
        end
      end
    end

    def empty_series
      Series.new(
        start_date: Date.current,
        end_date: Date.current,
        interval: "1 day",
        values: [],
        favorable_direction: favorable_direction
      )
    end
end
