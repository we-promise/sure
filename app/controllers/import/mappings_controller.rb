class Import::MappingsController < ApplicationController
  before_action :set_import

  def update
    @mapping = @import.mappings.find(params[:id])

    @mapping.update! \
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

    # The mapping row already declares what it maps to, so neither the target
    # class nor the mapping class comes from request params any more. Both used
    # to reach `constantize`, which resolves any constant in the application
    # and then had class methods and constants looked up on it (CWE-470).
    def mappable
      target_class = @mapping.mappable_class
      return nil unless target_class

      @mappable ||= target_class.find_by(id: mapping_params[:mappable_id], family: Current.family)
    end

    def create_when_empty
      mapping_params[:mappable_id] == Import::Mapping::CREATE_NEW_KEY
    end
end
