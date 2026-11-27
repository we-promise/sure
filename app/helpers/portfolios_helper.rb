module PortfoliosHelper
  # Where a holdings column header links: the same column flips direction,
  # another column opens on its natural direction (names ascending, figures
  # descending).
  def holdings_sort_link(key, active_sort:, active_dir:)
    next_dir = if active_sort == key
      active_dir == "asc" ? "desc" : "asc"
    else
      key == "name" ? "asc" : "desc"
    end
    portfolio_path(sort: key, dir: next_dir)
  end

  # The aria-sort value for a column header, or nil when it is not the
  # active sort (the attribute is omitted rather than set to "none").
  def holdings_aria_sort(key, active_sort:, active_dir:)
    return nil unless key && active_sort == key

    active_dir == "asc" ? "ascending" : "descending"
  end

  # A sortable holdings column's header: a link to its next sort, with the
  # direction's chevron on the active column.
  def holdings_sort_header(label, key, active_sort:, active_dir:)
    active = active_sort == key

    link_to holdings_sort_link(key, active_sort: active_sort, active_dir: active_dir),
            class: class_names("inline-flex items-center gap-1 hover:text-primary focus-ring rounded", "text-primary" => active) do
      safe_join([ label, (icon(active_dir == "asc" ? "chevron-up" : "chevron-down", size: "xs") if active) ].compact)
    end
  end

  # A KPI card's hint. Ordinarily just `label`; when an account has been
  # withheld for want of an exchange rate, it also says so, because a partial
  # figure that does not announce itself reads as a whole one.
  def kpi_hint(label, unconvertible_count)
    return label if unconvertible_count.to_i.zero?

    "#{label} · #{t('portfolios.kpi_row.unconvertible_accounts', count: unconvertible_count)}"
  end

  # The day change card's hint, only when some positions are left out of it.
  def kpi_day_change_hint((covered, total))
    t("portfolios.kpi_row.day_change_partial", covered: covered, total: total) if covered < total
  end

  # The unrealised P&L card's hint, only when a position is left out of it:
  # for want of a cost basis, or of an exchange rate.
  def kpi_unrealized_hint(missing_cost_basis_count, unconvertible_count = 0)
    parts = []
    parts << t("portfolios.kpi_row.unrealized_missing_cost_basis", count: missing_cost_basis_count) if missing_cost_basis_count.positive?
    parts << t("portfolios.kpi_row.unrealized_unconvertible", count: unconvertible_count) if unconvertible_count.positive?
    parts.join(" · ").presence
  end
end
