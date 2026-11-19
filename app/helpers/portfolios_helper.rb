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
end
