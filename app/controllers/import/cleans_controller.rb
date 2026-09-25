class Import::CleansController < ApplicationController
  layout "imports"

  before_action :set_import

  def show
    set_same_format_batch_navigation

    if @batch_first_import && @import != @batch_first_import
      return redirect_to import_clean_path(@batch_first_import)
    end

    unless @import.configured? || batch_import_configured?(@import)
      redirect_path = @import.is_a?(PdfImport) ? import_path(@import) : import_configuration_path(@import)
      return redirect_to redirect_path, alert: t(".not_configured")
    end

    rows = if @batch_imports.present?
      @batch_imports.flat_map { |batch_import| batch_import.rows_ordered.includes(:import).to_a }
    else
      @import.rows_ordered.to_a
    end
    @batch_clean = @batch_imports.present?
    @invalid_row_count = rows.count { |row| !row.valid? }
    @all_batch_imports_cleaned = if @batch_imports.present?
      @batch_imports.all? { |batch_import| batch_import_configured?(batch_import) } && @invalid_row_count.zero?
    else
      @import.cleaned?
    end
    @batch_complete = @batch_imports.present? ? @batch_imports.any?(&:complete?) : @import.complete?

    if params[:view] == "errors"
      rows = rows.reject(&:valid?)
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
    @categories = @import.family.categories.alphabetically_by_hierarchy
    @merchants = @import.family.available_merchants_for(Current.user).alphabetically
    @tags = @import.family.tags.alphabetically
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
      raise ActiveRecord::RecordNotFound if @import.account_statement.present? && !@import.account_statement.viewable_by?(Current.user)
    end

    def set_same_format_batch_navigation
      ids = Array(session[:same_format_csv_import_ids]).map(&:to_s)
      return unless ids.include?(@import.id.to_s)

      imports_by_id = Current.family.imports.where(id: ids).index_by { |import| import.id.to_s }
      imports = ids.filter_map { |id| imports_by_id[id] }
      return if imports.length < 2

      @batch_imports = imports
      @batch_first_import = imports.first
    end

    def batch_import_configured?(import)
      @batch_imports.present? && import.uploaded? && import.date_col_label.present? && import.amount_col_label.present?
    end
end
