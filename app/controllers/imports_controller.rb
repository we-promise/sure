class ImportsController < ApplicationController
  include SettingsHelper

  before_action :set_import, only: %i[show update publish destroy revert apply_template cancel summary]
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

      if @import.is_a?(PdfImport)
        # Refused for an import whose data already landed -- see
        # PdfImport#reassignable?. A replayed or back-button PATCH gets the
        # explanation rather than a silent unwind.
        unless @import.assign_account!(account)
          redirect_back_or_to import_path(@import), alert: t("imports.update.account_locked")
          return
        end
      else
        @import.update!(account: account)
      end
    end

    redirect_to import_path(@import), notice: t("imports.update.account_saved", default: "Account saved.")
  end

  def publish
    @import.publish_later

    redirect_to import_path(@import), notice: t(".started")
  rescue Import::MaxRowCountExceededError
    redirect_back_or_to import_path(@import), alert: t(".max_rows_exceeded", max: @import.max_row_count)
  end

  # Statement imports only: what became of each extracted transaction. Without it
  # a statement whose lines all matched finishes on the generic complete screen,
  # which cannot distinguish "everything was already recorded" from "nothing was
  # found".
  def summary
    raise ActiveRecord::RecordNotFound unless @import.is_a?(PdfImport)
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

  # Create one import or independently process a bounded batch of uploaded files.
  def create
    files = Array(import_params[:import_file]).reject(&:blank?).filter_map do |upload|
      upload if upload.respond_to?(:original_filename) && upload.respond_to?(:content_type)
    end
    file = files.first

    if files.size > 1 && document_upload_request? &&
        (files.size > Import::MAX_BATCH_UPLOAD_FILES || files.sum(&:size) > Import::MAX_BATCH_UPLOAD_SIZE)
      redirect_to new_import_path, alert: t(
        "imports.create.batch_upload_limit",
        count: Import::MAX_BATCH_UPLOAD_FILES,
        size: Import::MAX_BATCH_UPLOAD_SIZE / 1.megabyte
      )
      return
    end

    if files.size > 1 && document_upload_request?
      create_multiple_document_imports(files)
      return
    end

    if file.present? && document_upload_request?
      create_document_import(file)
      return
    end

    if file.present? && sure_import_request?
      create_sure_import(file)
      return
    end

    # Handle PDF file uploads - process with AI
    if file.present? && (Import::ALLOWED_PDF_MIME_TYPES.include?(file.content_type) || File.extname(file.original_filename.to_s).casecmp?(".pdf"))
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

  # Destroy an import only if its current locked state still permits deletion.
  def destroy
    unless @import.destroy_if_directly_deletable!
      redirect_to imports_path, alert: t("imports.destroy.not_deletable")
      return
    end

    redirect_to imports_path, notice: t(".deleted")
  end

  # Delete selected imports independently and summarize deleted and skipped records.
  def destroy_all
    import_ids = Array(params.dig(:bulk_delete, :import_ids)).filter_map { |id| id.to_s.presence }
    if import_ids.size > Import::MAX_BATCH_DELETE_IMPORTS
      redirect_to imports_path, alert: t("imports.destroy_all.limit", count: Import::MAX_BATCH_DELETE_IMPORTS)
      return
    end

    imports = Current.family.imports.where(id: import_ids).includes(:account_statement)
    deleted_count = 0
    skipped_count = 0

    imports.each do |import|
      can_manage_statement = import.account_statement.blank? || import.account_statement.manageable_by?(Current.user)

      if can_manage_statement && import.destroy_if_directly_deletable!
        deleted_count += 1
      else
        skipped_count += 1
      end
    rescue StandardError => error
      skipped_count += 1
      Rails.logger.warn("Bulk import deletion skipped #{import.type} #{import.id}: #{error.class}: #{error.message}")
    end

    notices = []
    notices << t("imports.destroy_all.deleted", count: deleted_count) if deleted_count.positive?
    alerts = []
    alerts << t("imports.destroy_all.skipped", count: skipped_count) if skipped_count.positive?
    alerts << t("imports.destroy_all.none_selected") if deleted_count.zero? && skipped_count.zero?

    redirect_to imports_path, notice: notices.presence&.join(" "), alert: alerts.presence&.join(" ")
  end

  private
    def set_import
      @import = Current.family.imports.includes(:account, :account_statement).find(params[:id])
      raise ActiveRecord::RecordNotFound if @import.account_statement.present? && !@import.account_statement.viewable_by?(Current.user)
    end

    def import_params
      params.require(:import).permit(:import_file, import_file: [])
    end

    def require_statement_import_permission!
      return if @import.account_statement.blank? || @import.account_statement.manageable_by?(Current.user)

      redirect_target = @import.account || @import.account_statement
      redirect_back_or_to redirect_target, alert: t("accounts.not_authorized")
    end

    def create_pdf_import(file)
      return redirect_to new_import_path, alert: t("accounts.not_authorized") unless AccountStatement.statement_manager?(Current.user)
      return redirect_to new_import_path, alert: t("imports.create.pdf_too_large", max_size: Import::MAX_PDF_SIZE / 1.megabyte) if file.size > Import::MAX_PDF_SIZE

      pdf_import = create_pdf_import_record(file)
      pdf_import.process_with_ai_later
      redirect_to import_path(pdf_import), notice: t("imports.create.pdf_processing")
    rescue AccountStatement::DuplicateUploadError
      redirect_to new_import_path, alert: t("imports.create.duplicate_pdf_unavailable")
    rescue AccountStatement::InvalidUploadError
      redirect_to new_import_path, alert: t("imports.create.invalid_pdf")
    end

    # Upload supported documents independently while preserving per-file errors.
    def create_multiple_document_imports(files)
      adapter = VectorStore.adapter
      unless adapter
        redirect_to new_import_path, alert: t("imports.create.document_provider_not_configured")
        return
      end

      supported_extensions = adapter.supported_extensions.map(&:downcase)
      processed_count = 0
      uploaded_count = 0
      errors = []

      files.each do |file|
        filename = file.original_filename.to_s

        is_pdf = file.content_type.in?(Import::ALLOWED_PDF_MIME_TYPES) || File.extname(filename).casecmp?(".pdf")
        if is_pdf
          unless valid_pdf_file?(file)
            errors << "#{filename}: #{t('imports.create.invalid_pdf')}"
            next
          end

          unless AccountStatement.statement_manager?(Current.user)
            errors << "#{filename}: #{t('accounts.not_authorized')}"
            next
          end

          if file.size > Import::MAX_PDF_SIZE
            errors << "#{filename}: #{t('imports.create.pdf_too_large', max_size: Import::MAX_PDF_SIZE / 1.megabyte)}"
            next
          end

          pdf_import = create_pdf_import_record(file)
          if pdf_import.process_with_ai_later
            processed_count += 1
          else
            errors << "#{filename}: #{t('imports.create.pdf_processing_failed')}"
          end
        else
          ext = File.extname(filename).downcase

          if file.size > Import::MAX_PDF_SIZE
            errors << "#{filename}: #{t('imports.create.document_too_large', max_size: Import::MAX_PDF_SIZE / 1.megabyte)}"
            next
          end

          unless supported_extensions.include?(ext)
            errors << "#{filename}: #{t('imports.create.invalid_document_file_type')}"
            next
          end

          document = Current.family.upload_document(file_content: file.read, filename: filename)
          if document
            uploaded_count += 1
          else
            errors << "#{filename}: #{t('imports.create.document_upload_failed')}"
          end
        end
      rescue AccountStatement::DuplicateUploadError
        errors << "#{filename}: #{t('imports.create.duplicate_pdf_unavailable')}"
      rescue AccountStatement::InvalidUploadError
        errors << "#{filename}: #{t('imports.create.invalid_pdf')}"
      rescue StandardError => e
        Rails.logger.error("Batch document upload failed for #{filename}: #{e.class}: #{e.message}")
        errors << "#{filename}: #{t('imports.create.document_upload_failed')}"
      end

      if processed_count.positive? || uploaded_count.positive?
        notices = []
        notices << t("imports.create.pdf_processing_many", count: processed_count) if processed_count.positive?
        notices << t("imports.create.document_uploaded_many", count: uploaded_count) if uploaded_count.positive?
        redirect_to imports_path, notice: notices.join(" "), alert: errors.presence&.join("\n")
      else
        redirect_to new_import_path, alert: errors.presence&.join("\n") || t("imports.create.document_upload_failed")
      end
    end

    def create_pdf_import_record(file)
      PdfImport.create_from_upload!(family: Current.family, file: file, user: Current.user)
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
      if file.size > SureImport.max_ndjson_size
        redirect_to new_import_path, alert: t("imports.create.file_too_large", max_size: SureImport.max_ndjson_size / 1.megabyte)
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
