class Category::Merger
  class UnauthorizedCategoryError < StandardError; end

  attr_reader :family, :target_category, :source_categories, :merged_count

  def initialize(family:, target_category:, source_categories:)
    @family = family
    @target_category = target_category
    @merged_count = 0

    validate_category_belongs_to_family!(target_category, "Target category")

    sources = Array(source_categories)
    sources.each { |category| validate_category_belongs_to_family!(category, "Source category '#{category.name}'") }

    @source_categories = sources.reject { |category| category.id == target_category.id }
    validate_hierarchy!
    validate_reparenting!
  end

  def merge!
    return false if source_categories.empty?

    if Category.connection.transaction_open?
      merge_sources!
    else
      Category.transaction { merge_sources! }
    end

    true
  end

  private
    def merge_sources!
      source_categories.each do |source|
        merge_transactions(source)
        merge_budget_categories(source)
        reparent_subcategories(source)
        source.destroy!
        @merged_count += 1
      end
    end

    def validate_category_belongs_to_family!(category, label)
      return if category&.family_id == family.id

      raise UnauthorizedCategoryError, "#{label} does not belong to this family"
    end

    def validate_hierarchy!
      target_ancestor_ids = ancestor_ids_for(target_category)

      source_categories.each do |source|
        next unless target_ancestor_ids.include?(source.id)

        raise UnauthorizedCategoryError, "A parent category cannot be merged into its own subcategory"
      end
    end

    def validate_reparenting!
      return if target_category.parent_id.blank?

      source_categories.each do |source|
        next unless family.categories.exists?(parent_id: source.id)

        raise UnauthorizedCategoryError, "Cannot merge a category with subcategories into a subcategory"
      end
    end

    def ancestor_ids_for(category)
      ids = []
      seen_ids = Set.new
      current = category

      while current&.parent_id.present? && seen_ids.exclude?(current.parent_id)
        ids << current.parent_id
        seen_ids << current.parent_id
        current = family.categories.find_by(id: current.parent_id)
      end

      ids
    end

    def merge_transactions(source)
      family.transactions.where(category_id: source.id).update_all(category_id: target_category.id)
    end

    def merge_budget_categories(source)
      source.budget_categories.find_each do |source_budget_category|
        target_budget_category = BudgetCategory.find_by(
          budget_id: source_budget_category.budget_id,
          category_id: target_category.id
        )

        if target_budget_category
          target_budget_category.update!(
            budgeted_spending: budgeted_spending_total(target_budget_category, source_budget_category)
          )
          source_budget_category.destroy!
        else
          source_budget_category.update!(category_id: target_category.id)
        end
      end
    end

    def reparent_subcategories(source)
      family.categories.where(parent_id: source.id).where.not(id: target_category.id).update_all(parent_id: target_category.id)
    end

    def budgeted_spending_total(target_budget_category, source_budget_category)
      (target_budget_category.budgeted_spending || 0).to_d + (source_budget_category.budgeted_spending || 0).to_d
    end
end
