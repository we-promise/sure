class Import::RowsController < ApplicationController
  include ImportGuestGuardable

  before_action :set_import
  before_action :require_import_editable!, only: :update
  around_action :lock_changeable_import, only: :update
  # After the lock: a configuration change regenerates the rows.
  before_action :set_import_row

  def update
    @row.update_and_sync(row_params)

    redirect_to import_row_path(@row.import, @row)
  end

  def show
  end

  private
    def row_params
      params.require(:import_row).permit(:type, :account, :date, :qty, :ticker, :price, :amount, :currency, :name, :category, :tags, :entity_type, :notes, :category_color, :category_classification, :category_parent, :category_icon)
    end

    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def set_import_row
      @row = @import.rows.find(params[:id])
    end
end
