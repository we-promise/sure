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

      scope = mappable_class.where(family: Current.family)
      scope = scope.merge(Account.writable_by(Current.user)) if mappable_class == Account
      @mappable ||= scope.find_by(id: mapping_params[:mappable_id])
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
