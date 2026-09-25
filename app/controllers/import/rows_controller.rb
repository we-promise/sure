class Import::RowsController < ApplicationController
  before_action :set_import_row, except: :destroy_invalid
  before_action :set_import, only: :destroy_invalid

  def update
    @row.update_and_sync(row_params, sync_mappings: false)
    sync_mappings(same_format_batch_imports.presence || [ @row.import ])

    redirect_to import_row_path(@row.import, @row)
  end

  def show
  end

  def destroy
    return redirect_to import_clean_path(@import) if @import.complete?

    @row.destroy!
    sync_mappings(same_format_batch_imports.presence || [ @import ])

    redirect_to clean_return_path, notice: t("import.rows.destroy.success")
  end

  def destroy_invalid
    return redirect_to import_clean_path(@import), alert: t("import.rows.destroy.completed_import") if @import.complete?

    imports = same_format_batch_imports.presence || [ @import ]
    return redirect_to import_clean_path(@import), alert: t("import.rows.destroy.completed_import") if imports.any?(&:complete?)

    invalid_count = 0
    imports.each do |import|
      invalid_ids = import.rows_ordered.to_a.reject(&:valid?).map(&:id)
      invalid_count += invalid_ids.size
      import.rows.where(id: invalid_ids).destroy_all
    end
    sync_mappings(imports)

    redirect_to import_clean_path(imports.first, view: "errors"),
      notice: t("import.rows.destroy.invalid_rows_success", count: invalid_count)
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def same_format_batch_imports
      ids = Array(session[:same_format_csv_import_ids]).map(&:to_s)
      return [] unless ids.include?(@import.id.to_s)

      imports_by_id = Current.family.imports.where(id: ids).index_by { |import| import.id.to_s }
      ids.filter_map { |id| imports_by_id[id] }
    end

    def sync_mappings(imports)
      imports.first.sync_mappings(batch_imports: imports)
    end

    def clean_return_path
      batch_ids = Array(session[:same_format_csv_import_ids]).map(&:to_s)
      if params[:batch_clean_id].present? && batch_ids.include?(params[:batch_clean_id].to_s) && batch_ids.include?(@import.id.to_s)
        first_import = Current.family.imports.find_by(id: batch_ids.first)
        return import_clean_path(first_import, view: params[:view], per_page: params[:per_page]) if first_import
      end

      import_clean_path(@import, view: params[:view], per_page: params[:per_page])
    end

    def row_params
      permitted = params.require(:import_row).permit(:type, :account, :date, :qty, :ticker, :price, :amount, :currency, :name, :merchant_id, :category_id, :category, :tags, :entity_type, :notes, :category_color, :category_classification, :category_parent, :category_icon, tag_ids: [])
      permitted[:merchant_id] = @import.family.merchants.where(id: permitted[:merchant_id]).pick(:id) if permitted.key?(:merchant_id)
      permitted[:category_id] = @import.family.categories.where(id: permitted[:category_id]).pick(:id) if permitted.key?(:category_id)
      permitted
    end

    def set_import_row
      set_import
      @row = @import.rows.find(params[:id])
    end
end
