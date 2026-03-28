module BudgetsHelper
  def budget_has_over_budget?(budget)
    return false unless budget.initialized?

    budget.budget_categories.any? { |budget_category| budget_any_over_budget?(budget_category) }
  end

  def budget_categories_view_state(budget)
    @budget_categories_view_state ||= {}
    @budget_categories_view_state[budget.object_id] ||= build_budget_categories_view_state(budget)
  end

  def budget_any_over_budget?(budget_category)
    budget_unbudgeted_with_spending?(budget_category) || budget_over_budget_with_budget?(budget_category)
  end

  def budget_on_track?(budget_category)
    budget_budgeted?(budget_category) && !budget_category.over_budget?
  end

  def budget_over_budget_with_budget?(budget_category)
    budget_budgeted?(budget_category) && budget_category.over_budget?
  end

  private

    def build_budget_categories_view_state(budget)
      uncategorized_budget_category = budget.uncategorized_budget_category
      all_category_groups = BudgetCategory::Group.for(budget.budget_categories)

      over_budget_groups = if budget.initialized?
        filtered_groups_for(all_category_groups) { |budget_category| budget_any_over_budget?(budget_category) }
      else
        []
      end

      show_over_budget_uncategorized = budget.initialized? && budget_any_over_budget?(uncategorized_budget_category)
      over_budget_count = visible_count_for(over_budget_groups) { |budget_category| budget_any_over_budget?(budget_category) }
      over_budget_count += 1 if show_over_budget_uncategorized

      on_track_groups = if budget.initialized?
        filtered_groups_for(all_category_groups) { |budget_category| budget_on_track?(budget_category) }
      else
        all_category_groups
      end

      show_on_track_uncategorized = all_category_groups.any? && (!budget.initialized? || budget_on_track?(uncategorized_budget_category))
      on_track_count = visible_count_for(on_track_groups) { |budget_category| parent_visible_for_on_track?(budget, budget_category) }
      on_track_count += 1 if show_on_track_uncategorized
      visible_expenses_empty = on_track_count.zero?

      {
        uncategorized_budget_category: uncategorized_budget_category,
        visible_expenses_empty: visible_expenses_empty,
        over_budget_groups: over_budget_groups,
        show_over_budget_uncategorized: show_over_budget_uncategorized,
        over_budget_count: over_budget_count,
        on_track_groups: on_track_groups,
        show_on_track_uncategorized: show_on_track_uncategorized,
        on_track_count: on_track_count
      }
    end

    def budget_budgeted?(budget_category)
      budget_category.display_budgeted_spending.to_d.positive?
    end

    def budget_unbudgeted_with_spending?(budget_category)
      !budget_budgeted?(budget_category) && budget_category.actual_spending.to_d.positive?
    end

    def parent_visible_for_on_track?(budget, budget_category)
      budget.initialized? ? budget_on_track?(budget_category) : true
    end

    def filtered_groups_for(groups)
      groups.each_with_object([]) do |group, filtered_groups|
        visible_subcategories = group.budget_subcategories.select { |budget_category| yield(budget_category) }
        next unless yield(group.budget_category) || visible_subcategories.any?

        filtered_groups << BudgetCategory::Group.new(group.budget_category, visible_subcategories)
      end
    end

    def visible_count_for(groups)
      groups.sum do |group|
        (yield(group.budget_category) ? 1 : 0) + group.budget_subcategories.count
      end
    end
end
