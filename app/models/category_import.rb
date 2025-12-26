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
    { categories: rows_count }
  end

  def csv_template
    template = <<-CSV
      name*,color,parent_category,classification,lucide_icon
      Food & Drink,#f97316,,expense,carrot
      Groceries,#407706,Food & Drink,expense,shopping-basket
      Salary,#22c55e,,income,briefcase
    CSV

    CSV.parse(template, headers: true)
  end

  def generate_rows_from_csv
    rows.destroy_all

    validate_required_headers!

    name_header = header_for("name")
    color_header = header_for("color")
    parent_header = header_for("parent_category", "parent category")
    classification_header = header_for("classification")
    icon_header = header_for("lucide_icon", "lucide icon", "icon")

    csv_rows.each do |row|
      rows.create!(
        name: row[name_header].to_s.strip,
        category_color: row[color_header].to_s.strip,
        category_parent: row[parent_header].to_s.strip,
        category_classification: row[classification_header].to_s.strip,
        category_icon: row[icon_header].to_s.strip,
        currency: default_currency
      )
    end
  end

  private
    def validate_required_headers!
      missing_headers = required_column_keys.map(&:to_s).reject { |key| header_for(key).present? }
      return if missing_headers.empty?

      errors.add(:base, "Missing required columns: #{missing_headers.join(', ')}")
      raise ActiveRecord::RecordInvalid.new(self)
    end

    def header_for(*candidates)
      candidates.each do |candidate|
        normalized = normalize_header(candidate)
        header = normalized_headers[normalized]
        return header if header.present?
      end

      nil
    end

    def normalized_headers
      @normalized_headers ||= csv_headers.to_h { |header| [ normalize_header(header), header ] }
    end

    def normalize_header(header)
      header.to_s.strip.downcase.gsub(/\*/, "").gsub(/[\s-]+/, "_")
    end

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
