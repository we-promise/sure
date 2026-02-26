class Import::CategoryMapping < Import::Mapping
  class << self
    def mappables_by_key(import)
      unique_values = import.rows.map(&:category).uniq

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
      parts = key.split(":", 2)
      parts.length == 2 ? parts[1].strip : key
    end
  end

  def selectable_values
    family_categories = import.family.categories.alphabetically.map { |category| [ category.name, category.id ] }

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

      # Ensure the parent category exists before creating the child.
      parent = import.family.categories.find_or_create_by!(name: parent_name)

      self.mappable = import.family.categories.find_or_create_by!(name: child_name) do |cat|
        cat.parent = parent
      end
    else
      self.mappable = import.family.categories.find_or_create_by!(name: key)
    end

    save!
  end
end
