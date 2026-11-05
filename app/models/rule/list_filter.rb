# What the rules page needs to search and filter its list in the browser: a
# search text per rule and the values of each filter. Option lists are read
# once per condition or action type, not once per rule, so the page stays at
# a fixed number of queries however many rules there are.
class Rule::ListFilter
  def initialize(rules)
    @rules = rules.to_a
    @condition_options = {}
    @action_options = {}
  end

  # The rule's name with the labels and values of its conditions and actions,
  # e.g. "Groceries Merchant Rewe Set category Food".
  def search_text(rule)
    parts = [ rule.name ]

    leaf_conditions(rule).each do |condition|
      parts << condition.filter.label << condition_value(condition)
    end

    rule.actions.each do |action|
      parts << action.executor.label << action_value(action)
    end

    parts.compact_blank.join(" ")
  end

  def action_types(rule)
    rule.actions.map(&:action_type).uniq
  end

  def condition_types(rule)
    leaf_conditions(rule).map(&:condition_type).uniq
  end

  # Only accounts the user can see, so the page holds no ids of others.
  def account_ids(rule)
    condition_account_ids(rule) & account_options.map { |_name, id| id.to_s }
  end

  # [label, key] pairs for the types the family's rules use.
  def action_type_options
    type_options(rules.flat_map(&:actions)) { |action| [ action.executor.label, action.action_type ] }
  end

  def condition_type_options
    type_options(rules.flat_map { |rule| leaf_conditions(rule) }) { |condition| [ condition.filter.label, condition.condition_type ] }
  end

  # [name, id] pairs for the accounts the rules' conditions name. Accounts the
  # user cannot see are left out, as they are in the rule form.
  def account_options
    @account_options ||= begin
      ids = rules.flat_map { |rule| condition_account_ids(rule) }.to_set
      condition = rules.lazy.flat_map { |rule| leaf_conditions(rule) }.find { |c| c.condition_type == "transaction_account" }
      condition ? Array(condition_options_for(condition)).select { |_name, id| ids.include?(id.to_s) } : []
    end
  end

  private
    attr_reader :rules

    def condition_account_ids(rule)
      leaf_conditions(rule).select { |condition| condition.condition_type == "transaction_account" }.map(&:value).compact_blank.uniq
    end

    # Conditions inside a condition group count like those at the top.
    def leaf_conditions(rule)
      rule.conditions.flat_map { |condition| condition.compound? ? condition.sub_conditions.to_a : [ condition ] }
    end

    def type_options(records)
      records.map { |record| yield(record) }.uniq(&:last).sort_by { |label, _key| label.to_s.downcase }
    end

    def condition_value(condition)
      return if condition.value.blank?

      options = condition_options_for(condition)
      return condition.value unless options

      options.find { |_label, id| id.to_s == condition.value.to_s }&.first
    end

    def action_value(action)
      return if action.value.blank?

      # Structured values (e.g. a split's JSON) have their own summary.
      custom_display = action.executor.value_display(action.value)
      return custom_display if custom_display

      # A free-text action (e.g. set the name) has no options: its value is
      # the text itself.
      options = action_options_for(action)
      return action.value if options.nil?
      return if options.empty?

      values = action.executor.type == "multi_select" ? action.value.to_s.split(",") : [ action.value.to_s ]
      labels_by_id = options.to_h { |label, id| [ id.to_s, label ] }
      values.filter_map { |value| labels_by_id[value] }.join(" ")
    end

    def condition_options_for(condition)
      @condition_options.fetch(condition.condition_type) do
        @condition_options[condition.condition_type] = condition.options
      end
    end

    def action_options_for(action)
      @action_options.fetch(action.action_type) do
        @action_options[action.action_type] = action.options
      end
    end
end
