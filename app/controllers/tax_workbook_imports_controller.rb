class TaxWorkbookImportsController < ApplicationController
  before_action :require_admin
  before_action :set_import, only: %i[show download destroy]

  def index
    @pagy, @imports = pagy(
      Current.family.tax_workbook_imports.with_attached_source_file.ordered,
      limit: safe_per_page
    )
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.tax_workbook_imports"), tax_workbook_imports_path ]
    ]

    render layout: "settings"
  end

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.tax_workbook_imports"), tax_workbook_imports_path ],
      [ @import.filename, nil ]
    ]

    render layout: "settings"
  end

  def create
    result = TaxWorkbook::Parser.new(
      family: Current.family,
      uploaded_by: Current.user,
      file: workbook_upload_params[:file]
    ).call

    if result.success?
      redirect_to tax_workbook_import_path(result.import), notice: t("tax_workbook_imports.create.success")
    elsif result.import&.persisted?
      redirect_to tax_workbook_import_path(result.import), alert: t("tax_workbook_imports.create.failure")
    else
      redirect_to tax_workbook_imports_path, alert: import_failure_alert(result.errors)
    end
  end

  def template
    send_data TaxWorkbook::TemplateGenerator.new.call,
              filename: "sure-india-tax-workbook-template.xlsx",
              type: TaxWorkbookImport::XLSX_CONTENT_TYPE,
              disposition: "attachment"
  end

  def download
    unless @import.source_file.attached?
      redirect_to tax_workbook_import_path(@import), alert: t("tax_workbook_imports.download.missing")
      return
    end

    redirect_to rails_blob_path(@import.source_file, disposition: "attachment")
  end

  def destroy
    @import.destroy
    redirect_to tax_workbook_imports_path, notice: t("tax_workbook_imports.destroy.success")
  end

  private
    def set_import
      @import = Current.family.tax_workbook_imports.with_attached_source_file.find(params[:id])
    end

    def workbook_upload_params
      params.fetch(:tax_workbook_import, ActionController::Parameters.new).permit(:file)
    end

    def import_failure_alert(errors)
      errors.filter_map { |error| error["message"] }.to_sentence.presence || t("tax_workbook_imports.create.failure")
    end

    def require_admin
      return if Current.user&.admin?

      redirect_to root_path, alert: t("accounts.not_authorized")
    end
end
