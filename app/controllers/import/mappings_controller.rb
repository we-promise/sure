class Import::MappingsController < ApplicationController
  before_action :set_import

  def update
    mapping = @import.mappings.find(params[:id])

    mapping.update! \
      create_when_empty: create_when_empty,
      mappable: mappable,
      value: mapping_params[:value]

    redirect_back_or_to import_confirm_path(@import)
  end

  private
    def mapping_params
      params.require(:import_mapping).permit(:type, :key, :mappable_id, :mappable_type, :value)
    end

    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def mappable
      return nil unless mappable_class.present?

      @mappable ||= mappable_class.find_by(id: mapping_params[:mappable_id], family: Current.family)
    end

    def create_when_empty
      return false unless mapping_class.present?

      mapping_params[:mappable_id] == mapping_class::CREATE_NEW_KEY
    end

    ALLOWED_MAPPABLE_TYPES = %w[Category Tag Account].freeze
    ALLOWED_MAPPING_TYPES = %w[
      Import::CategoryMapping Import::TagMapping
      Import::AccountMapping Import::AccountTypeMapping
    ].freeze

    def mappable_class
      type = mapping_params[:mappable_type]
      return nil unless type.present? && ALLOWED_MAPPABLE_TYPES.include?(type)
      type.constantize
    end

    def mapping_class
      type = mapping_params[:type]
      return nil unless type.present? && ALLOWED_MAPPING_TYPES.include?(type)
      type.constantize
    end
end
