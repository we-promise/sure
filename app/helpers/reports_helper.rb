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

  # Treemap nodes for the "Spending vs normal" section: each drawable row of
  # the comparison (IncomeStatement::SpendingComparison#row_json) plus the
  # formatted labels, the tooltip lines and the Transactions link.
  def spending_treemap_nodes(comparison, start_date:, end_date:)
    comparison.drawable_rows.map do |row|
      labelled = row.subcategories.size > 1
      spending_treemap_node(comparison, row, start_date:, end_date:).merge(
        children: row.subcategories.map do |sub|
          spending_treemap_node(comparison, sub, parent: row, direct_label: labelled, start_date:, end_date:)
        end
      )
    end
  end

  # The change list: rows that moved against normal, with the bar width as a
  # share of the largest change.
  def spending_changes(comparison, start_date:, end_date:)
    changes = comparison.changes
    max_change = changes.map { |row| row.change.abs }.max

    changes.map do |row|
      {
        row: row,
        width: (row.change.abs / max_change * 100).round(1),
        amount_label: "#{row.change.negative? ? "−" : "+"}#{spending_money(comparison, row.change.abs, precision: 0)}",
        href: spending_category_href(row.category, start_date:, end_date:)
      }
    end
  end

  private
    def spending_treemap_node(comparison, row, start_date:, end_date:, parent: nil, direct_label: false)
      name = row.direct && direct_label ? t("reports.spending_vs_normal.direct", category: row.category.name) : row.category.name

      comparison.row_json(row).merge(
        name: name,
        direct: row.direct,
        total: row.total.to_f,
        total_label: spending_money(comparison, row.total, precision: 0),
        ratio: row.ratio&.to_f,
        change_sign: row.change && (row.change.negative? ? -1 : 1),
        has_normal: comparison.comparable? && !row.normal.nil?,
        description: spending_description(comparison, row, parent && name != parent.category.name ? t("reports.spending_vs_normal.tooltip.path", parent: parent.category.name, category: name) : name),
        href: spending_category_href(row.category, start_date:, end_date:)
      )
    end

    def spending_description(comparison, row, name)
      lines = [ t("reports.spending_vs_normal.tooltip.total", category: name, amount: spending_money(comparison, row.total)) ]
      unless comparison.comparable? && row.normal
        return lines << t("reports.spending_vs_normal.tooltip.no_normal")
      end

      lines << t("reports.spending_vs_normal.tooltip.normal", amount: spending_money(comparison, row.normal))
      if row.change.abs >= IncomeStatement::SpendingComparison::MIN_CHANGE
        direction = row.change.negative? ? "less" : "more"
        amount = spending_money(comparison, row.change.abs)
        lines << if row.ratio
          t("reports.spending_vs_normal.tooltip.#{direction}", amount: amount, percent: number_to_percentage(row.ratio.abs * 100, precision: 0))
        else
          t("reports.spending_vs_normal.tooltip.#{direction}_no_percent", amount: amount)
        end
      end
      lines
    end

    def spending_money(comparison, amount, precision: 2)
      Money.new(amount, comparison.currency).format(precision: precision)
    end

    def spending_category_href(category, start_date:, end_date:)
      transactions_path(q: { categories: [ category.filter_value ], start_date: start_date, end_date: end_date })
    end
end
