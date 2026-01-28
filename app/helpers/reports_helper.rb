module ReportsHelper
  # Returns CSS classes for tax treatment badge styling
  def tax_treatment_badge_classes(treatment)
    case treatment.to_sym
    when :tax_exempt
      "bg-green-500/10 text-green-600 theme-dark:text-green-400"
    when :tax_deferred
      "bg-blue-500/10 text-blue-600 theme-dark:text-blue-400"
    when :tax_advantaged
      "bg-purple-500/10 text-purple-600 theme-dark:text-purple-400"
    else
      "bg-gray-500/10 text-secondary"
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
end
