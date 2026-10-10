module ReportsHelper
  # Returns the DS::Pill tone for a given tax treatment. Mirrors the
  # mapping used by `accounts/_tax_treatment_badge.html.erb` so the
  # report and the per-account badge stay visually aligned.
  def tax_treatment_pill_tone(treatment)
    case treatment.to_sym
    when :tax_exempt     then :green
    when :tax_deferred   then :indigo  # was raw blue-500/10 → closest DS tone
    when :tax_advantaged then :violet  # was raw purple-500/10 → closest DS tone
    else                      :neutral
    end
  end

  # Generate SVG polyline points for a sparkline chart
  # Returns empty string if fewer than 2 data points (can't draw a line with 1 point)
  def sparkline_points(values, width: 60, height: 16)
    return "" if values.nil? || values.length < 2 || values.all? { |v| v.nil? || v.zero? }

    nums = values.map(&:to_f)
    max_val = nums.max
    min_val = nums.min
    range = max_val - min_val
    range = 1.0 if range.zero?

    points = nums.each_with_index.map do |val, i|
      x = (i.to_f / [ nums.length - 1, 1 ].max) * width
      y = height - ((val - min_val) / range * (height - 2)) - 1
      "#{x.round(1)},#{y.round(1)}"
    end

    points.join(" ")
  end

  # Calculate cumulative net values from trends data
  def cumulative_net_values(trends)
    return [] if trends.nil?

    running = 0
    trends.map { |t| running += t[:net].to_i; running }
  end

  # Check if trends data has enough points for sparklines (need at least 2)
  def has_sparkline_data?(trends_data)
    trends_data&.length.to_i >= 2
  end
  def monthly_spending_share(amount, total)
    return "—" unless total.to_d.positive?
    number_to_percentage(amount.to_d / total.to_d * 100, precision: 1, strip_insignificant_zeros: true)
  end

  def monthly_spending_selected_ids(key, default)
    value = params[key]
    value.is_a?(Array) && value.all? { |id| id.is_a?(String) } ? value.reject(&:blank?) : default
  end

  def monthly_spending_period_options
    year = Date.current.year
    [
      [ t("pages.dashboard.monthly_spending.last_twelve"), "last_twelve" ],
      [ t("pages.dashboard.monthly_spending.this_year"), "this_year" ],
      *(1..3).map { |offset| [ (year - offset).to_s, "year:#{year - offset}" ] }
    ]
  end
end
