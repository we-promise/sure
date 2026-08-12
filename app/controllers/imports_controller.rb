class ImportsController < ApplicationController
  include SettingsHelper

  before_action :set_import, only: %i[show update publish destroy revert apply_template cancel]
  before_action :require_statement_import_permission!, only: %i[update publish destroy revert apply_template cancel]

  def update
    # Handle both pdf_import[account_id] and import[account_id] param formats
    account_id = params.dig(:pdf_import, :account_id) || params.dig(:import, :account_id)

    if account_id.present?
      account = accessible_accounts.find_by(id: account_id)
      unless account
        redirect_back_or_to import_path(@import), alert: t("imports.update.invalid_account", default: "Account not found.")
        return
      end
      return if @import.account_statement.present? && !require_account_permission!(account)

      @import.is_a?(PdfImport) ? @import.assign_account!(account) : @import.update!(account: account)
    end

    redirect_to import_path(@import), notice: t("imports.update.account_saved", default: "Account saved.")
  end

  def publish
    @import.publish_later

    redirect_to import_path(@import), notice: t(".started")
  rescue Import::MaxRowCountExceededError
    redirect_back_or_to import_path(@import), alert: t(".max_rows_exceeded", max: @import.max_row_count)
  end

  def cancel
    if @import.force_fail!
      redirect_to imports_path, notice: t(".cancelled")
    else
      redirect_to imports_path, alert: t(".not_cancellable")
    end
  end

  def index
    @pagy, @imports = pagy(Current.family.imports.where(type: Import::TYPES).ordered, limit: safe_per_page)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.imports"), imports_path ]
    ]
    respond_to do |format|
      format.html { render layout: "settings" }
    end
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

    if file.present? && sure_import_request?
      create_sure_import(file)
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

    account = accessible_accounts.find_by(id: params.dig(:import, :account_id))
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
    unless @import.requires_csv_workflow?
      redirect_to import_upload_path(@import), alert: t("imports.show.finalize_upload") unless @import.uploaded?
      return
    end

    if !@import.uploaded?
      redirect_to import_upload_path(@import), alert: t("imports.show.finalize_upload")
    elsif !@import.publishable?
      next_path = @import.mapping_steps.empty? ? import_clean_path(@import) : import_confirm_path(@import)
      redirect_to next_path, alert: t("imports.show.finalize_mappings")
    end
  end

  def revert
    @import.revert_later
    redirect_to imports_path, notice: t(".started")
  end

  def apply_template
    if @import.suggested_template
      @import.apply_template!(@import.suggested_template)
      redirect_to import_configuration_path(@import), notice: t(".template_applied")
    else
      redirect_to import_configuration_path(@import), alert: t(".no_template_found")
    end
  end

  def destroy
    @import.destroy

    redirect_to imports_path, notice: t(".deleted")
  end

  private
    def set_import
      @import = Current.family.imports.includes(:account, :account_statement).find(params[:id])
      raise ActiveRecord::RecordNotFound if @import.account_statement.present? && !@import.account_statement.viewable_by?(Current.user)
    end

    def import_params
      params.require(:import).permit(:import_file)
    end

    def require_statement_import_permission!
      return if @import.account_statement.blank? || @import.account_statement.manageable_by?(Current.user)

      redirect_target = @import.account || @import.account_statement
      redirect_back_or_to redirect_target, alert: t("accounts.not_authorized")
    end

    def create_pdf_import(file)
      return redirect_to new_import_path, alert: t("accounts.not_authorized") unless AccountStatement.statement_manager?(Current.user)
      return redirect_to new_import_path, alert: t("imports.create.pdf_too_large", max_size: Import::MAX_PDF_SIZE / 1.megabyte) if file.size > Import::MAX_PDF_SIZE

      pdf_import = PdfImport.create_from_upload!(family: Current.family, file: file, user: Current.user)
      pdf_import.process_with_ai_later
      redirect_to import_path(pdf_import), notice: t("imports.create.pdf_processing")
    rescue AccountStatement::DuplicateUploadError
      redirect_to new_import_path, alert: t("imports.create.duplicate_pdf_unavailable")
    rescue AccountStatement::InvalidUploadError
      redirect_to new_import_path, alert: t("imports.create.invalid_pdf")
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

    def sure_import_request?
      params.dig(:import, :type) == "SureImport"
    end

    def create_sure_import(file)
      if file.size > SureImport::MAX_NDJSON_SIZE
        redirect_to new_import_path, alert: t("imports.create.file_too_large", max_size: SureImport::MAX_NDJSON_SIZE / 1.megabyte)
        return
      end

      ext = File.extname(file.original_filename.to_s).downcase
      unless ext.in?(%w[.ndjson .json])
        redirect_to new_import_path, alert: t("imports.create.invalid_ndjson_file_type")
        return
      end

      content = file.read
      file.rewind
      unless SureImport.valid_ndjson_first_line?(content)
        redirect_to new_import_path, alert: t("imports.create.invalid_ndjson_file_type")
        return
      end

      import = Current.family.imports.create!(type: "SureImport")
      import.ndjson_file.attach(
        io: StringIO.new(content),
        filename: file.original_filename,
        content_type: file.content_type
      )
      import.sync_ndjson_rows_count!

      redirect_to import_path(import), notice: t("imports.create.ndjson_uploaded")
    end

    def valid_pdf_file?(file)
      header = file.read(5)
      file.rewind
      header&.start_with?("%PDF-")
    end
end
