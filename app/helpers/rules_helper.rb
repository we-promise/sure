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

  # "#3 Groceries", with its run position, linking to the rule's form for
  # those who can edit it.
  def rule_health_reference(rule, position)
    label = t("rules.health.rule_label", position: position, name: rule.name.presence || rule.primary_condition_title)
    reference = if Current.user&.guest?
      tag.span(label, class: "font-medium text-primary")
    else
      link_to(label, edit_rule_path(rule), class: "font-medium text-primary underline", data: { turbo_frame: "modal" })
    end
    rule.active? ? reference : safe_join([ reference, tag.span(t("rules.health.inactive"), class: "text-secondary") ], " ")
  end

  # e.g. "If transaction name like woolworths · Set transaction category to
  # Groceries": the condition and action the rules list shows first.
  def rule_summary(rule)
    "#{rule.primary_condition_title} · #{rule_action_label(rule.displayed_action)}"
  end

  # e.g. "Set transaction category to Groceries", as the rules list shows a
  # rule's first action.
  def rule_action_label(action)
    if action.nil?
      t("rules.no_action")
    elsif action.value && action.options
      t("rules.rule.action_label_to", label: action.executor.label, value: action.value_display)
    else
      action.executor.label
    end
  end

  # e.g. "category and merchant", for the fields a Rule::Health entry names.
  def rule_health_attributes(attributes)
    attributes.map { |attribute| t("rules.health.attributes.#{attribute}", default: attribute.to_s.humanize(capitalize: false)) }.to_sentence
  end
end
