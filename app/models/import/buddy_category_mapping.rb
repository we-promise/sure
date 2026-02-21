class Import::BuddyCategoryMapping < Import::Mapping
  class << self
    def mappables_by_key(import)
      unique_categories = import.rows.pluck(:category, :category_parent).uniq
      all_categories = import.family.categories.index_by(&:name)
      result = {}

      unique_categories.each do |child_name, parent_name|
        child_name = child_name.to_s.strip
        parent_name = parent_name.to_s.strip
        next if child_name.blank?

        key = parent_name.present? ? "#{parent_name} > #{child_name}" : child_name

        parent = all_categories[parent_name] if parent_name.present?
        category = if parent
          all_categories.values.find { |c| c.name == child_name && c.parent_id == parent.id }
        else
          all_categories[child_name]
        end

        result[key] = category
      end

      result
    end
  end

  def selectable_values
    family_categories = import.family.categories.alphabetically.map { |c| [ c.name, c.id ] }
    family_categories.unshift [ "Add as new category", CREATE_NEW_KEY ] unless key.blank?
    family_categories
  end

  def requires_selection?
    false
  end

  def values_count
    parts = key.split(" > ", 2)
    if parts.length == 2
      import.rows.where(category_parent: parts[0], category: parts[1]).count
    else
      import.rows.where(category: key).count
    end
  end

  def mappable_class
    Category
  end

  def create_mappable!
    return unless creatable?

    parts = key.split(" > ", 2)
    if parts.length == 2
      parent_name, child_name = parts
      parent = import.family.categories.find_or_create_by!(name: parent_name.strip) do |cat|
        cat.classification = parent_name.strip.downcase == "income" ? "income" : "expense"
        cat.color = Category::UNCATEGORIZED_COLOR
        cat.lucide_icon = "shapes"
      end
      self.mappable = import.family.categories.find_or_create_by!(name: child_name.strip) do |cat|
        cat.parent = parent
        cat.classification = parent.classification
        cat.color = Category::UNCATEGORIZED_COLOR
        cat.lucide_icon = "shapes"
      end
    else
      self.mappable = import.family.categories.find_or_create_by!(name: key.strip)
    end
    save!
  end
end
