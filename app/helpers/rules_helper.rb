module RulesHelper
  FILTER_ICONS = { status: "toggle-right", action_type: "zap", condition_type: "filter", account: "layers", group: "folder" }.freeze

  # The tabs of the rules filter popover, each as { name:, label:, icon:, items:, selected: }.
  # Each name is also the URL parameter that keeps the filter on a reload.
  # Filters with nothing to choose from are left out, and a value from the
  # URL that is not offered selects "all".
  def rule_filters(list_filter, groups)
    filters = {
      status: [ [ t("rules.filters.status.active"), "active" ], [ t("rules.filters.status.inactive"), "inactive" ] ],
      action_type: list_filter.action_type_options,
      condition_type: list_filter.condition_type_options,
      account: list_filter.account_options,
      group: groups.any? ? [ [ t("rules.filters.group.none"), "none" ] ] + groups.map { |group| [ group.name, group.id ] } : []
    }

    filters.filter_map do |name, options|
      next if options.empty?

      items = [ { label: t("rules.filters.#{name}.all"), value: "" } ] + options.map { |label, value| { label: label, value: value.to_s } }
      selected = params[name].to_s
      selected = "" unless items.any? { |item| item[:value] == selected }

      { name: name, label: t("rules.filters.#{name}.label"), icon: FILTER_ICONS.fetch(name), items: items, selected: selected }
    end
  end
end
