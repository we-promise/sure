class CategoryImport < Import
  def import!
    transaction do
      rows.each do |row|
        category_name = row.name.to_s.strip
        category = family.categories.find_or_initialize_by(name: category_name)
        category.color = row.category_color.presence || category.color || Category::UNCATEGORIZED_COLOR
        category.classification = row.category_classification.presence || category.classification || "expense"
        category.lucide_icon = row.category_icon.presence || category.lucide_icon || "shapes"
        category.parent = nil
        category.save!

        ensure_placeholder_category(row.category_parent)
      end

      rows.each do |row|
        category = family.categories.find_by!(name: row.name.to_s.strip)
        parent = ensure_placeholder_category(row.category_parent)

        if parent && parent == category
          errors.add(:base, "Category '#{category.name}' cannot be its own parent")
          raise ActiveRecord::RecordInvalid.new(self)
        end

        next if category.parent == parent

        category.update!(parent: parent)
      end
    end
  end

  def column_keys
    %i[name category_color category_parent category_classification category_icon]
  end

  def required_column_keys
    %i[name]
  end

  def mapping_steps
    []
  end

  def dry_run
    { categories: rows.count }
  end

  def csv_template
    template = <<-CSV
      name*,color,parent_category,classification,lucide-icon
      Food & Drink,#f97316,,expense,carrot
      Groceries,#407706,Food & Drink,expense,shopping-basket
      Salary,#22c55e,,income,briefcase
    CSV

    CSV.parse(template, headers: true)
  end

  def generate_rows_from_csv
    rows.destroy_all

    csv_rows.each do |row|
      rows.create!(
        name: row["name"].to_s.strip,
        category_color: row["color"].to_s.strip,
        category_parent: row["parent_category"].to_s.strip,
        category_classification: row["classification"].to_s.strip,
        category_icon: (row["lucide-icon"].presence || row["icon"]).to_s.strip,
        currency: default_currency
      )
    end
  end

  private

    def ensure_placeholder_category(name)
      trimmed_name = name.to_s.strip
      return if trimmed_name.blank?

      family.categories.find_or_create_by!(name: trimmed_name) do |placeholder|
        placeholder.color = Category::UNCATEGORIZED_COLOR
        placeholder.classification = "expense"
        placeholder.lucide_icon = "shapes"
      end
    end
end
