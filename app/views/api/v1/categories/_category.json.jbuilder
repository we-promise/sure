# frozen_string_literal: true

json.id category.id
json.name category.name
json.classification category.classification
json.color category.color
json.icon category.lucide_icon

# Parent information (for subcategories)
if category.parent.present?
  json.parent do
    json.id category.parent.id
    json.name category.parent.name
  end
else
  json.parent nil
end

# Subcategories count (for parent categories)
json.subcategories_count category.subcategories.size

json.created_at category.created_at.iso8601
json.updated_at category.updated_at.iso8601
