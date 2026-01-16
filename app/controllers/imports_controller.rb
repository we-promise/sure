class ImportsController < ApplicationController
  include SettingsHelper

  before_action :set_import, only: %i[show publish destroy revert apply_template]

  def publish
    @import.publish_later

    redirect_to import_path(@import), notice: "Your import has started in the background."
  rescue Import::MaxRowCountExceededError
    redirect_back_or_to import_path(@import), alert: "Your import exceeds the maximum row count of #{@import.max_row_count}."
  end

  def index
    @imports = Current.family.imports
    @exports = Current.user.admin? ? Current.family.family_exports.ordered.limit(10) : nil
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Import/Export", imports_path ]
    ]
    render layout: "settings"
  end

  def new
    @pending_import = Current.family.imports.ordered.pending.first
  end

  def create
    file = import_params[:csv_file]

    # Handle PDF file uploads - process with AI
    if file.present? && Import::ALLOWED_PDF_MIME_TYPES.include?(file.content_type)
      create_pdf_import(file)
      return
    end

    type = params.dig(:import, :type).to_s
    type = "TransactionImport" unless Import::TYPES.include?(type)

    account = Current.family.accounts.find_by(id: params.dig(:import, :account_id))
    import = Current.family.imports.create!(
      type: type,
      account: account,
      date_format: Current.family.date_format,
    )

    if file.present?
      if file.size > Import::MAX_CSV_SIZE
        import.destroy
        redirect_to new_import_path, alert: t("imports.create.file_too_large", max_size: Import::MAX_CSV_SIZE / 1.megabyte)
        return
      end

      unless Import::ALLOWED_MIME_TYPES.include?(file.content_type)
        import.destroy
        redirect_to new_import_path, alert: t("imports.create.invalid_file_type")
        return
      end

      # Stream reading is not fully applicable here as we store the raw string in the DB,
      # but we have validated size beforehand to prevent memory exhaustion from massive files.
      import.update!(raw_file_str: file.read)
      redirect_to import_configuration_path(import), notice: t("imports.create.csv_uploaded")
    else
      redirect_to import_upload_path(import)
    end
  end

  def show
    # PDF imports have their own flow - show the summary page
    return if @import.is_a?(PdfImport)

    if !@import.uploaded?
      redirect_to import_upload_path(@import), alert: t("imports.show.finalize_upload")
    elsif !@import.publishable?
      redirect_to import_confirm_path(@import), alert: t("imports.show.finalize_mappings")
    end
  end

  def revert
    @import.revert_later
    redirect_to imports_path, notice: "Import is reverting in the background."
  end

  def apply_template
    if @import.suggested_template
      @import.apply_template!(@import.suggested_template)
      redirect_to import_configuration_path(@import), notice: "Template applied."
    else
      redirect_to import_configuration_path(@import), alert: "No template found, please manually configure your import."
    end
  end

  def destroy
    @import.destroy

    redirect_to imports_path, notice: "Your import has been deleted."
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:id])
    end

    def import_params
      params.require(:import).permit(:csv_file)
    end

    def create_pdf_import(file)
      if file.size > Import::MAX_PDF_SIZE
        redirect_to new_import_path, alert: t("imports.create.pdf_too_large", max_size: Import::MAX_PDF_SIZE / 1.megabyte)
        return
      end

      pdf_import = Current.family.imports.create!(type: "PdfImport")
      pdf_import.pdf_file.attach(file)
      pdf_import.process_with_ai_later

      redirect_to import_path(pdf_import), notice: t("imports.create.pdf_processing")
    end
end
