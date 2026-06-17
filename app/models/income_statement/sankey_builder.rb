# Builds the nodes/links payload consumed by the cashflow Sankey chart
# (app/javascript/controllers/sankey_chart_controller.js). Shared by the
# dashboard and reports cashflow widgets.
#
# Takes the net/income/expense totals produced by IncomeStatement for a period
# and returns { nodes:, links:, currency_symbol: }.
class IncomeStatement::SankeyBuilder
  def initialize(net_totals:, income_totals:, expense_totals:, currency:)
    @net_totals = net_totals
    @income_totals = income_totals
    @expense_totals = expense_totals
    @currency = currency
  end

  def build
    nodes = []
    links = []
    node_indices = {}

    add_node = ->(unique_key, display_name, value, percentage, color) {
      node_indices[unique_key] ||= begin
        nodes << { id: unique_key, name: display_name, value: value.to_f.round(2), percentage: percentage.to_f.round(1), color: color }
        nodes.size - 1
      end
    }

    total_income = net_totals.total_net_income.to_f.round(2)
    total_expense = net_totals.total_net_expense.to_f.round(2)

    # Central Cash Flow node
    cash_flow_idx = add_node.call("cash_flow_node", "Cash Flow", total_income, 100.0, "var(--color-success)")

    # Build netted subcategory data from raw totals
    net_subcategories_by_parent = build_net_subcategories(expense_totals, income_totals)

    # Process net income categories (flow: subcategory -> parent -> cash_flow)
    process_net_category_nodes(
      categories: net_totals.net_income_categories,
      total: total_income,
      prefix: "income",
      net_subcategories_by_parent: net_subcategories_by_parent,
      add_node: add_node,
      links: links,
      cash_flow_idx: cash_flow_idx,
      flow_direction: :inbound
    )

    # Process net expense categories (flow: cash_flow -> parent -> subcategory)
    process_net_category_nodes(
      categories: net_totals.net_expense_categories,
      total: total_expense,
      prefix: "expense",
      net_subcategories_by_parent: net_subcategories_by_parent,
      add_node: add_node,
      links: links,
      cash_flow_idx: cash_flow_idx,
      flow_direction: :outbound
    )

    # Surplus/Deficit
    net = (total_income - total_expense).round(2)
    if net.positive?
      percentage = total_income.zero? ? 0 : (net / total_income * 100).round(1)
      idx = add_node.call("surplus_node", "Surplus", net, percentage, "var(--color-success)")
      links << { source: cash_flow_idx, target: idx, value: net, color: "var(--color-success)", percentage: percentage }
    end

    { nodes: nodes, links: links, currency_symbol: Money::Currency.new(currency).symbol }
  end

  private
    attr_reader :net_totals, :income_totals, :expense_totals, :currency

    # Nets subcategory expense and income totals, grouped by parent_id.
    # Returns { parent_id => [ { category:, total: net_amount }, ... ] }
    # Only includes subcategories with positive net (same direction as parent).
    def build_net_subcategories(expense_totals, income_totals)
      expense_subs = expense_totals.category_totals
        .select { |ct| ct.category.parent_id.present? }
        .index_by { |ct| ct.category.id }

      income_subs = income_totals.category_totals
        .select { |ct| ct.category.parent_id.present? }
        .index_by { |ct| ct.category.id }

      all_sub_ids = (expense_subs.keys + income_subs.keys).uniq
      result = {}

      all_sub_ids.each do |sub_id|
        exp_ct = expense_subs[sub_id]
        inc_ct = income_subs[sub_id]
        exp_total = exp_ct&.total || 0
        inc_total = inc_ct&.total || 0
        net = exp_total - inc_total
        category = exp_ct&.category || inc_ct&.category

        next if net.zero?

        parent_id = category.parent_id
        result[parent_id] ||= []
        result[parent_id] << { category: category, total: net.abs, net_direction: net > 0 ? :expense : :income }
      end

      result
    end

    # Builds sankey nodes/links for net categories with subcategory hierarchy.
    # Subcategories matching the parent's flow direction are shown as children.
    # Subcategories with opposite net direction appear on the OTHER side of the
    # sankey (handled when the other side calls this method).
    #
    # flow_direction: :inbound  (subcategory -> parent -> cash_flow) for income
    #                 :outbound (cash_flow -> parent -> subcategory) for expenses
    def process_net_category_nodes(categories:, total:, prefix:, net_subcategories_by_parent:, add_node:, links:, cash_flow_idx:, flow_direction:)
      matching_direction = flow_direction == :inbound ? :income : :expense

      categories.each do |ct|
        val = ct.total.to_f.round(2)
        next if val.zero?

        percentage = total.zero? ? 0 : (val / total * 100).round(1)
        color = ct.category.color.presence || Category::UNCATEGORIZED_COLOR
        node_key = "#{prefix}_#{ct.category.id || ct.category.name}"

        all_subs = ct.category.id ? (net_subcategories_by_parent[ct.category.id] || []) : []
        same_side_subs = all_subs.select { |s| s[:net_direction] == matching_direction }

        # Also check if any subcategory has opposite direction — those will be
        # rendered by the OTHER side's call to this method, linked to cash_flow
        # directly (they appear as independent nodes on the opposite side).
        opposite_subs = all_subs.select { |s| s[:net_direction] != matching_direction }

        if same_side_subs.any?
          parent_idx = add_node.call(node_key, ct.category.name, val, percentage, color)

          if flow_direction == :inbound
            links << { source: parent_idx, target: cash_flow_idx, value: val, color: color, percentage: percentage }
          else
            links << { source: cash_flow_idx, target: parent_idx, value: val, color: color, percentage: percentage }
          end

          same_side_subs.each do |sub|
            sub_val = sub[:total].to_f.round(2)
            sub_pct = val.zero? ? 0 : (sub_val / val * 100).round(1)
            sub_color = sub[:category].color.presence || color
            sub_key = "#{prefix}_sub_#{sub[:category].id}"
            sub_idx = add_node.call(sub_key, sub[:category].name, sub_val, sub_pct, sub_color)

            if flow_direction == :inbound
              links << { source: sub_idx, target: parent_idx, value: sub_val, color: sub_color, percentage: sub_pct }
            else
              links << { source: parent_idx, target: sub_idx, value: sub_val, color: sub_color, percentage: sub_pct }
            end
          end
        else
          idx = add_node.call(node_key, ct.category.name, val, percentage, color)

          if flow_direction == :inbound
            links << { source: idx, target: cash_flow_idx, value: val, color: color, percentage: percentage }
          else
            links << { source: cash_flow_idx, target: idx, value: val, color: color, percentage: percentage }
          end
        end

        # Render opposite-direction subcategories as standalone nodes on this side,
        # linked directly to cash_flow. They represent subcategory surplus/deficit
        # that goes against the parent's overall direction.
        opposite_prefix = flow_direction == :inbound ? "expense" : "income"
        opposite_subs.each do |sub|
          sub_val = sub[:total].to_f.round(2)
          sub_pct = total.zero? ? 0 : (sub_val / total * 100).round(1)
          sub_color = sub[:category].color.presence || color
          sub_key = "#{opposite_prefix}_sub_#{sub[:category].id}"
          sub_idx = add_node.call(sub_key, sub[:category].name, sub_val, sub_pct, sub_color)

          # Opposite direction: if parent is outbound (expense), this sub is inbound (income)
          if flow_direction == :inbound
            links << { source: cash_flow_idx, target: sub_idx, value: sub_val, color: sub_color, percentage: sub_pct }
          else
            links << { source: sub_idx, target: cash_flow_idx, value: sub_val, color: sub_color, percentage: sub_pct }
          end
        end
      end
    end
end
