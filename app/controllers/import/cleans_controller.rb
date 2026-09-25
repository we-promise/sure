class Import::CleansController < ApplicationController
  layout "imports"

  before_action :set_import

  def show
    unless @import.configured?
      redirect_path = @import.is_a?(PdfImport) ? import_path(@import) : import_configuration_path(@import)
      return redirect_to redirect_path, alert: t(".not_configured")
    end

    rows = @import.rows_ordered

    if params[:view] == "errors"
      rows = rows.reject { |row| row.valid? }
    end

    @per_page = params[:per_page].to_s
    @show_all = @per_page == "all"
    @per_page = "10" unless @show_all || %w[10 20 30 50 100].include?(@per_page)

    if @show_all
      @pagy = nil
      @rows = rows
    else
      @pagy, @rows = pagy_array(rows, limit: @per_page)
    end

    @show_pdf = @import.is_a?(PdfImport) && @import.pdf_uploaded? && params[:show_pdf] == "1" && params[:hide_pdf] != "1"
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
      raise ActiveRecord::RecordNotFound if @import.account_statement.present? && !@import.account_statement.viewable_by?(Current.user)
    end
end
