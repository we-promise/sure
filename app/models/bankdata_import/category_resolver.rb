# frozen_string_literal: true

module BankdataImport
  class CategoryResolver
    def initialize(family)
      @family = family
    end

    def resolve(parent_name:, category_name:)
      return nil if category_name.blank?

      parent = find_or_create(parent_name) if parent_name.present?
      find_or_create(category_name, parent: parent)
    end

    private
      attr_reader :family

      def find_or_create(name, parent: nil)
        category = family.categories.find_or_initialize_by(name: name)
        category.parent = parent if parent && category.parent_id.blank?
        category.color ||= parent&.color || "#4da568"
        category.lucide_icon ||= Category.suggested_icon(name)
        category.save!
        category
      end
  end
end
