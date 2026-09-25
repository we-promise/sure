class Import::ConfirmsController < ApplicationController
  layout "imports"

  before_action :set_import

  def show
    set_same_format_batch_navigation

    if @batch_first_import && @import != @batch_first_import
      return redirect_to import_confirm_path(@batch_first_import)
    end

    if @batch_imports.present? && !batch_cleaned?
      return redirect_to import_clean_path(@batch_first_import), alert: t(".invalid_data")
    end

    if @import.mapping_steps.empty?
      return redirect_to(@batch_first_import ? imports_path : import_path(@import))
    end

    redirect_to import_clean_path(@import), alert: t(".invalid_data") unless @batch_first_import ? batch_cleaned? : @import.cleaned?
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
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

    def batch_cleaned?
      @batch_imports.all? do |batch_import|
        batch_import.uploaded? && batch_import.date_col_label.present? && batch_import.amount_col_label.present? &&
          batch_import.rows.all?(&:valid?)
      end
    end
end
