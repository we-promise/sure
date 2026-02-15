class ImportsController < ApplicationController
  include SettingsHelper

  before_action :set_import, only: %i[show update publish destroy revert apply_template]

  def update
    # Handle both pdf_import[account_id] and import[account_id] param formats
    account_id = params.dig(:pdf_import, :account_id) || params.dig(:import, :account_id)

    if account_id.present?
      account = Current.family.accounts.find_by(id: account_id)
      unless account
        redirect_back_or_to import_path(@import), alert: t("imports.update.invalid_account", default: "Account not found.")
        return
      end
      @import.update!(account: account)
    end

    redirect_to import_path(@import), notice: t("imports.update.account_saved", default: "Account saved.")
  end

  def publish
    @import.publish_later

    redirect_to import_path(@import), notice: "Your import has started in the background."
  rescue Import::MaxRowCountExceededError
    redirect_back_or_to import_path(@import), alert: "Your import exceeds the maximum row count of #{@import.max_row_count}."
  end

  def index
    @pagy, @imports = pagy(Current.family.imports.where(type: Import::TYPES).ordered, limit: safe_per_page)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.imports"), imports_path ]
    ]
    render layout: "settings"
  end

  def new
    @pending_import = Current.family.imports.ordered.pending.first
    @document_upload_extensions = document_upload_supported_extensions
  end

  def create
    file = import_params[:import_file]

    if file.present? && document_upload_request?
      create_document_import(file)
      return
    end

    # Handle PDF file uploads - process with AI
    if file.present? && Import::ALLOWED_PDF_MIME_TYPES.include?(file.content_type)
      unless valid_pdf_file?(file)
        redirect_to new_import_path, alert: t("imports.create.invalid_pdf")
        return
      end
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

      unless Import::ALLOWED_CSV_MIME_TYPES.include?(file.content_type)
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
    return unless @import.requires_csv_workflow?

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
      @import = Current.family.imports.includes(:account).find(params[:id])
    end

    def import_params
      params.require(:import).permit(:import_file)
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

    def create_document_import(file)
      adapter = VectorStore.adapter
      unless adapter
        redirect_to new_import_path, alert: t("imports.create.document_provider_not_configured")
        return
      end

      if file.size > Import::MAX_PDF_SIZE
        redirect_to new_import_path, alert: t("imports.create.document_too_large", max_size: Import::MAX_PDF_SIZE / 1.megabyte)
        return
      end

      filename = file.original_filename.to_s
      ext = File.extname(filename).downcase
      supported_extensions = adapter.supported_extensions.map(&:downcase)

      unless supported_extensions.include?(ext)
        redirect_to new_import_path, alert: t("imports.create.invalid_document_file_type")
        return
      end

      if ext == ".pdf"
        unless valid_pdf_file?(file)
          redirect_to new_import_path, alert: t("imports.create.invalid_pdf")
          return
        end

        create_pdf_import(file)
        return
      end

      family_document = Current.family.upload_document(
        file_content: file.read,
        filename: filename
      )

      if family_document
        redirect_to new_import_path, notice: t("imports.create.document_uploaded")
      else
        redirect_to new_import_path, alert: t("imports.create.document_upload_failed")
      end
    end

    def document_upload_supported_extensions
      adapter = VectorStore.adapter
      return [] unless adapter

      adapter.supported_extensions.map(&:downcase).uniq.sort
    end

    def document_upload_request?
      params.dig(:import, :type) == "DocumentImport"
    end

    def valid_pdf_file?(file)
      header = file.read(5)
      file.rewind
      header&.start_with?("%PDF-")
    end
end
