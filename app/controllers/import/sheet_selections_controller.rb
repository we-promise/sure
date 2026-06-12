class Import::SheetSelectionsController < ApplicationController
  layout "imports"

  before_action :set_import
  before_action :ensure_xlsx_import

  def show
    redirect_to import_upload_path(@import), alert: t(".finalize_upload") and return unless @import.uploaded?

    @detected_sheets = @import.detected_sheets
    @accounts = accessible_accounts.manual.alphabetically
  rescue Import::XlsxWorkbook::Error => e
    redirect_to new_import_path, alert: t(".invalid_file", message: e.message)
  end

  def update
    @import.apply_sheet_selections!(sheet_selection_params)

    if @import.rows_count.zero?
      redirect_to import_sheet_selection_path(@import), alert: t(".no_sheets_selected")
    else
      redirect_to import_clean_path(@import), notice: t(".sheets_imported")
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to import_sheet_selection_path(@import), alert: e.record.errors.full_messages.to_sentence.presence || e.message
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def ensure_xlsx_import
      redirect_to import_path(@import) unless @import.is_a?(XlsxImport)
    end

    # params[:import][:sheets] is a hash keyed by index; each entry permits the
    # sheet name, a selected flag, and the chosen account ("new" or a uuid).
    def sheet_selection_params
      sheets = params.dig(:import, :sheets) || {}
      sheets.values.map do |sheet|
        sheet.permit(:sheet_name, :selected, :account_id, :account_name).to_h
      end
    end
end
