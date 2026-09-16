class Import::CategoryMapping < Import::Mapping
  class << self
    def mappables_by_key(import)
      unique_values = if import.is_a?(QifImport)
        import.row_categories
      else
        import.rows.map(&:category).uniq
      end

      # For hierarchical QIF keys like "Home:Home Improvement", look up the child
      # name ("Home Improvement") since category names are unique per family.
      lookup_names = unique_values.map { |v| leaf_category_name(v) }
      categories = import.family.categories.where(name: lookup_names).index_by(&:name)

      unique_values.index_with { |value| categories[leaf_category_name(value)] }
    end

    private

      # Returns the leaf (child) name for a potentially hierarchical key.
      # "Home:Home Improvement" → "Home Improvement"
      # "Fees & Charges"        → "Fees & Charges"
      def leaf_category_name(key)
        return "" if key.blank?

        parts = key.to_s.split(":", 2)
        parts.length == 2 ? parts[1].strip : key
      end
  end

  def selectable_values
    family_categories = Category::Group.select_options(import.family.categories)

    unless key.blank?
      family_categories.unshift [ "Add as new category", CREATE_NEW_KEY ]
    end

    family_categories
  end

  def requires_selection?
    false
  end

  def values_count
    import.rows.where(category: key).count
  end

  def mappable_class
    Category
  end

  def create_mappable!
    return unless creatable?

    parts = key.split(":", 2)

    if parts.length == 2
      parent_name = parts[0].strip
      child_name  = parts[1].strip

      # Ensure parent is a top-level category (subcategories cannot have children in Sure).
      parent = import.family.categories.roots.find_by(name: parent_name)

      if parent.nil?
        existing = import.family.categories.find_by(name: parent_name)
        if existing&.subcategory?
          parent = existing.parent
        else
          parent = create_root_category!(parent_name)
        end
      end

      self.mappable = import.family.categories.find_or_create_by!(name: child_name) do |cat|
        cat.parent = parent
        cat.color = parent.color
        cat.lucide_icon = Category.suggested_icon(child_name)
      end
    else
      self.mappable = import.family.categories.find_or_create_by!(name: key) do |cat|
        cat.color = Category::COLORS.sample
        cat.lucide_icon = Category.suggested_icon(key)
      end
    end

    save!
  end

  private
    def create_root_category!(name)
      import.family.categories.roots.create!(name: name) do |cat|
        cat.color = Category::COLORS.sample
        cat.lucide_icon = Category.suggested_icon(name)
      end
    rescue ActiveRecord::RecordNotUnique
      import.family.categories.roots.find_by!(name: name)
    rescue ActiveRecord::RecordInvalid => error
      raise unless error.record.is_a?(Category) && error.record.errors.of_kind?(:name, :taken)

      import.family.categories.roots.find_by!(name: name)
    end
end
