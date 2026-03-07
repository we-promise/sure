class Import::CleansController < ApplicationController
  layout "imports"

  before_action :set_import

  def show
    unless @import.configured?
      redirect_path = @import.is_a?(PdfImport) ? import_path(@import) : import_configuration_path(@import)
      return redirect_to redirect_path, alert: "Please configure your import before proceeding."
    end

    rows = @import.rows.ordered

    if params[:view] == "errors"
      rows = rows.reject { |row| row.valid? }
    end

    @pagy, @rows = pagy_array(rows, limit: params[:per_page] || "10")
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end
end
