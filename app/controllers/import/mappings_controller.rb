class Import::MappingsController < ApplicationController
  before_action :set_import

  def update
    mapping = @import.mappings.find(params[:id])

    mapping.update! \
      create_when_empty: create_when_empty,
      mappable: mappable,
      value: mapping_params[:value]

    sibling_imports.each do |sibling|
      sibling_mapping = sibling.mappings.find_by(type: mapping.type, key: mapping.key)
      next unless sibling_mapping

      sibling_mapping.update!(
        create_when_empty: mapping.create_when_empty,
        mappable: mapping.mappable,
        value: mapping.value
      )
    end

    redirect_back_or_to import_confirm_path(@import)
  end

  private
    def mapping_params
      params.require(:import_mapping).permit(:type, :key, :mappable_id, :mappable_type, :value)
    end

    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def sibling_imports
      ids = Array(session[:same_format_csv_import_ids]).map(&:to_s)
      return Import.none unless ids.include?(@import.id.to_s)

      Current.family.imports.where(id: ids).where.not(id: @import.id)
    end

    def mappable
      return nil unless mappable_class.present?

      @mappable ||= mappable_class.find_by(id: mapping_params[:mappable_id], family: Current.family)
    end

    def create_when_empty
      return false unless mapping_class.present?

      mapping_params[:mappable_id] == mapping_class::CREATE_NEW_KEY
    end

    def mappable_class
      mapping_params[:mappable_type]&.constantize
    end

    def mapping_class
      mapping_params[:type]&.constantize
    end
end
