class Import::MappingsController < ApplicationController
  before_action :set_import

  def update
    mapping = @import.mappings.find(params[:id])

    mapping.update! \
      create_when_empty: create_when_empty(mapping),
      mappable: mappable(mapping),
      value: mapping_params[:value]

    redirect_back_or_to import_confirm_path(@import)
  end

  private
    # SECURITY: `type` and `mappable_type` are deliberately not permitted here. The form
    # submits them as hidden fields, so they are attacker-controlled, and they used to be
    # resolved with `constantize` — which turns a request parameter into an arbitrary
    # constant lookup. Both are derived from the persisted mapping record instead (see
    # `mappable` / `create_when_empty`), which already knows its own type.
    def mapping_params
      params.require(:import_mapping).permit(:key, :mappable_id, :value)
    end

    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    # The mapping subclass declares which model it maps to (Account/Category/Tag, or nil
    # for value-based mappings like Import::AccountTypeMapping), so the class never comes
    # from the request. Scoping to `Current.family` still guards the record itself.
    def mappable(mapping)
      mappable_class = mapping.mappable_class
      return nil unless mappable_class.present?

      mappable_class.find_by(id: mapping_params[:mappable_id], family: Current.family)
    end

    def create_when_empty(mapping)
      return false unless mapping.mappable_class.present?

      mapping_params[:mappable_id] == mapping.class::CREATE_NEW_KEY
    end
end
