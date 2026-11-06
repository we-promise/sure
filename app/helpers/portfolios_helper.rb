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

  # Deterministic segment colours for the allocation donut: the chart palette
  # the app already uses for categories, indexed by the segment's position, so
  # a grouping renders the same colours on every reload.
  def allocation_color(index)
    Category::COLORS[index % Category::COLORS.size]
  end

  # The donut-chart controller's segment contract, as the dashboard's
  # outflows donut builds it (id, name, amount, currency, percentage, color).
  def allocation_segments_json(segments, currency:)
    segments.each_with_index.map do |segment, index|
      {
        id: segment.id,
        name: segment.name,
        amount: segment.amount.amount.to_f.round(2),
        currency: currency,
        percentage: segment.weight.to_f.round(1),
        color: allocation_color(index)
      }
    end.to_json
  end

  # Segment names arrive as stored keys, not display text -- `equity`,
  # `north_america`, `unclassified` -- because that is what the taxonomy stores
  # so the label can be translated. Anything without a key of its own (a
  # security, an account, a currency, and the provider free text in `sector`)
  # is shown as it comes.
  ALLOCATION_TRANSLATED_GROUPINGS = {
    "kind" => "kinds",
    "asset_class" => "asset_classes",
    "asset_sub_class" => "asset_sub_classes",
    "region" => "regions"
  }.freeze

  # The grouping one level down, so a child row's label is translated in its own
  # vocabulary rather than its parent's.
  def allocation_child_grouping(by)
    by.to_s == "asset_class" ? "asset_sub_class" : "security"
  end

  # The asset class the level below hangs from. A sub-class name repeats across
  # asset classes (`unclassified` is under every one), so the positions under a
  # sub-class reached from an asset class are limited to that class; below any
  # other level the parent carries through unchanged.
  def allocation_child_parent(by, segment, parent)
    by.to_s == "asset_class" ? segment.id : parent
  end

  def allocation_segment_name(segment, by)
    # By id, not by name: a real security actually called "unclassified" would
    # otherwise have its name replaced with the translated bucket label.
    return t("portfolios.allocation.unclassified") if segment.id == InvestmentStatement::UNCLASSIFIED

    scope = ALLOCATION_TRANSLATED_GROUPINGS[by.to_s]
    return segment.name if scope.nil?

    # `default:` rather than a bare lookup: `sector` is provider free text and
    # `region` could carry a value the config named before this list did, and a
    # missing label should show the value rather than "translation missing".
    t("portfolios.allocation.#{scope}.#{segment.name}", default: segment.name)
  end
end
