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
    type = params[:type].presence_in(csv_import_types)
    type ||= accessible_accounts.any? ? "TransactionImport" : "AccountImport"
    type = "AccountImport" if type.in?(%w[TransactionImport TradeImport]) && accessible_accounts.none?
    import = Current.family.imports.pending.where(type: type, raw_file_str: nil).ordered.first
    import ||= Current.family.imports.create!(type: type, date_format: Current.family.date_format)

    redirect_to import_upload_path(import, file_format: import_file_format(import)), status: :see_other
  end

  def check_pdf_duplicate
    content_sha256 = params[:content_sha256].to_s
    byte_size = params[:byte_size].to_s
    unless content_sha256.match?(/\A[0-9a-f]{64}\z/) && byte_size.match?(/\A\d+\z/) && byte_size.to_i.positive? && byte_size.to_i <= AccountStatement::MAX_LARGE_PDF_SIZE
      return render json: { duplicate: false }, status: :unprocessable_entity
    end

    duplicate = PdfImport.duplicate_content?(family: Current.family, content_sha256: content_sha256, byte_size: byte_size.to_i)
    render json: { duplicate: duplicate }
  end

  # Create one import or independently process the selected upload batch.
  def create
    files = Array(import_params[:import_file]).reject(&:blank?).filter_map do |upload|
      upload if upload.respond_to?(:original_filename) && upload.respond_to?(:content_type)
    end
    file = files.first

    allow_large_upload = import_params[:allow_large_upload] == "true"
    allow_duplicate_upload = import_params[:allow_duplicate_upload] == "true"

    if files.any? && files.sum(&:size) > Import::MAX_BATCH_UPLOAD_SIZE
      redirect_to new_import_path,
                  alert: t("imports.create.files_total_exceeds_max_size", max_size: Import::MAX_BATCH_UPLOAD_SIZE / 1.megabyte)
      return
    end

    if files.size > 1 && document_upload_request?
      account = selected_document_account
      return if performed?

      create_multiple_document_imports(files, account: account, allow_large_upload: allow_large_upload, allow_duplicate_upload: allow_duplicate_upload)
      return
    end

    if file.present? && document_upload_request?
      create_document_import(file, allow_large_upload: allow_large_upload, allow_duplicate_upload: allow_duplicate_upload)
      return
    end

    if file.present? && sure_import_request?
      if files.size > 1
        create_multiple_sure_imports(files)
      else
        create_sure_import(file)
      end
      return
    end

    # Handle PDF file uploads - process with AI
    if file.present? && (Import::ALLOWED_PDF_MIME_TYPES.include?(file.content_type) || File.extname(file.original_filename.to_s).casecmp?(".pdf"))
      unless valid_pdf_file?(file)
        redirect_to new_import_path, alert: t("imports.create.invalid_pdf")
        return
      end
      create_pdf_import(file, allow_large_upload: allow_large_upload, allow_duplicate_upload: allow_duplicate_upload)
      return
    end

    if files.size > 1
      create_multiple_csv_imports(files)
      return
    end

    type = requested_import_type.to_s
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
      csv_format = params.dig(:import, :csv_format) if import.is_a?(TransactionImport)
      redirect_to import_upload_path(import, csv_format: csv_format)
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
    unauthorized_count = 0
    not_deletable_count = 0
    error_count = 0

    imports.each do |import|
      can_manage_statement = import.account_statement.blank? || import.account_statement.manageable_by?(Current.user)

      if !can_manage_statement
        unauthorized_count += 1
      elsif import.destroy_if_directly_deletable!
        deleted_count += 1
      else
        not_deletable_count += 1
      end
    rescue StandardError => error
      error_count += 1
      Rails.logger.warn("Bulk import deletion skipped #{import.type} #{import.id}: #{error.class}: #{error.message}")
    end

    notices = []
    notices << t("imports.destroy_all.deleted", count: deleted_count) if deleted_count.positive?
    alerts = []
    alerts << t("imports.destroy_all.unauthorized", count: unauthorized_count) if unauthorized_count.positive?
    alerts << t("imports.destroy_all.not_deletable", count: not_deletable_count) if not_deletable_count.positive?
    alerts << t("imports.destroy_all.failed", count: error_count) if error_count.positive?
    no_matching_imports = deleted_count.zero? && unauthorized_count.zero? && not_deletable_count.zero? && error_count.zero?
    alerts << t("imports.destroy_all.none_selected") if no_matching_imports

    redirect_to imports_path, notice: notices.presence&.join(" "), alert: alerts.presence&.join(" ")
  end

  private
    def set_import
      @import = Current.family.imports.includes(:account, :account_statement).find(params[:id])
      raise ActiveRecord::RecordNotFound if @import.account_statement.present? && !@import.account_statement.viewable_by?(Current.user)
    end

    def import_params
      params.require(:import).permit(:account_id, :allow_large_upload, :allow_duplicate_upload, import_file: [])
    end

    def require_statement_import_permission!
      return if @import.account_statement.blank? || @import.account_statement.manageable_by?(Current.user)

      redirect_target = @import.account || @import.account_statement
      redirect_back_or_to redirect_target, alert: t("accounts.not_authorized")
    end

    def create_pdf_import(file, account: nil, allow_large_upload: false, allow_duplicate_upload: false)
      return redirect_to new_import_path, alert: t("accounts.not_authorized") unless AccountStatement.statement_manager?(Current.user)
      if file.size > AccountStatement::MAX_LARGE_PDF_SIZE
        redirect_to new_import_path, alert: t("imports.create.file_exceeds_max_size", max_size: AccountStatement::MAX_LARGE_PDF_SIZE / 1.megabyte)
        return
      end
      if file.size > Import::UPLOAD_WARNING_SIZE && !allow_large_upload
        redirect_to new_import_path, alert: t("imports.create.pdf_too_large", max_size: Import::UPLOAD_WARNING_SIZE / 1.megabyte)
        return
      end
      return unless account.blank? || require_account_permission!(account)

      pdf_import = PdfImport.create_from_upload!(
        family: Current.family,
        file: file,
        user: Current.user,
        account: account,
        allow_large_pdf: allow_large_upload,
        allow_duplicate_upload: allow_duplicate_upload
      )
      if account.present? && pdf_import.account_id != account.id && !pdf_import.assign_account!(account)
        redirect_to import_path(pdf_import), alert: t("imports.update.account_locked")
        return
      end
      processing_started = pdf_import.process_with_ai_later
      unless processing_started || pdf_import.importing? || pdf_import.complete?
        redirect_to new_import_path, alert: t("imports.create.pdf_processing_failed")
        return
      end

      notice = processing_started ? t("imports.create.pdf_processing") : t("imports.create.duplicate_pdf_reused")
      redirect_to import_path(pdf_import), notice: notice
    rescue PdfImport::DuplicateUploadError => error
      message = error.statement && !error.statement.manageable_by?(Current.user) ? "duplicate_pdf_unavailable" : "duplicate_pdf_unconfirmed"
      redirect_to new_import_path, alert: t("imports.create.#{message}")
    rescue AccountStatement::InvalidUploadError
      redirect_to new_import_path, alert: t("imports.create.invalid_pdf")
    end

    # Upload supported documents independently while preserving per-file errors.
    def create_multiple_document_imports(files, account: nil, allow_large_upload: false, allow_duplicate_upload: false)
      adapter = VectorStore.adapter
      unless adapter
        redirect_to new_import_path, alert: t("imports.create.document_provider_not_configured")
        return
      end

      contains_pdf = files.any? do |file|
        file.content_type.in?(Import::ALLOWED_PDF_MIME_TYPES) || File.extname(file.original_filename.to_s).casecmp?(".pdf")
      end
      return unless account.blank? || !contains_pdf || require_account_permission!(account)

      supported_extensions = adapter.supported_extensions.map(&:downcase)
      processed_count = 0
      uploaded_count = 0
      reused_count = 0
      errors = []
      handled_pdf_import_ids = {}

      files.each do |file|
        filename = file.original_filename.to_s

        if file.size > Import::UPLOAD_WARNING_SIZE && !allow_large_upload
          errors << "#{filename}: #{t('imports.create.document_file_too_large', max_size: Import::UPLOAD_WARNING_SIZE / 1.megabyte)}"
          next
        end

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

          pdf_import = create_pdf_import_record(file, account: account, allow_large_pdf: allow_large_upload, allow_duplicate_upload: allow_duplicate_upload)
          if account.present? && pdf_import.account_id != account.id && !pdf_import.assign_account!(account)
            errors << "#{filename}: #{t('imports.update.account_locked')}"
            next
          end
          if handled_pdf_import_ids[pdf_import.id]
            next
          end

          handled_pdf_import_ids[pdf_import.id] = true
          if pdf_import.process_with_ai_later
            processed_count += 1
          elsif pdf_import.importing? || pdf_import.complete?
            reused_count += 1
          else
            errors << "#{filename}: #{t('imports.create.pdf_processing_failed')}"
          end
        else
          ext = File.extname(filename).downcase

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
      rescue PdfImport::DuplicateUploadError => error
        message = error.statement && !error.statement.manageable_by?(Current.user) ? "duplicate_pdf_unavailable" : "duplicate_pdf_unconfirmed"
        errors << "#{filename}: #{t("imports.create.#{message}")}"
      rescue AccountStatement::InvalidUploadError
        errors << "#{filename}: #{t('imports.create.invalid_pdf')}"
      rescue StandardError => e
        Rails.logger.error("Batch document upload failed for #{filename}: #{e.class}: #{e.message}")
        errors << "#{filename}: #{t('imports.create.document_upload_failed')}"
      end

      if processed_count.positive? || uploaded_count.positive?
        notices = []
        notices << t("imports.create.pdf_processing_many", count: processed_count) if processed_count.positive?
        notices << t("imports.create.duplicate_pdf_reused_many", count: reused_count) if reused_count.positive?
        notices << t("imports.create.document_uploaded_many", count: uploaded_count) if uploaded_count.positive?
        redirect_to imports_path, notice: notices.join(" "), alert: errors.presence&.join("\n")
      elsif reused_count.positive?
        redirect_to imports_path, notice: t("imports.create.duplicate_pdf_reused_many", count: reused_count), alert: errors.presence&.join("\n")
      else
        redirect_to new_import_path, alert: errors.presence&.join("\n") || t("imports.create.document_upload_failed")
      end
    end

    def create_pdf_import_record(file, account: nil, allow_large_pdf: false, allow_duplicate_upload: false)
      PdfImport.create_from_upload!(family: Current.family, file: file, user: Current.user, account: account, allow_large_pdf: allow_large_pdf, allow_duplicate_upload: allow_duplicate_upload)
    end

    def create_document_import(file, allow_large_upload: false, allow_duplicate_upload: false)
      filename = file.original_filename.to_s
      ext = File.extname(filename).downcase

      if Import::ALLOWED_PDF_MIME_TYPES.include?(file.content_type) || ext == ".pdf"
        unless valid_pdf_file?(file)
          redirect_to new_import_path, alert: t("imports.create.invalid_pdf")
          return
        end

        account = accessible_accounts.find_by(id: import_params[:account_id]) if import_params[:account_id].present?
        unless import_params[:account_id].blank? || account
          redirect_to new_import_path, alert: t("imports.update.invalid_account", default: "Account not found.")
          return
        end

        create_pdf_import(file, account: account, allow_large_upload: allow_large_upload, allow_duplicate_upload: allow_duplicate_upload)
        return
      end

      adapter = VectorStore.adapter
      unless adapter
        redirect_to new_import_path, alert: t("imports.create.document_provider_not_configured")
        return
      end

      supported_extensions = adapter.supported_extensions.map(&:downcase)
      unless supported_extensions.include?(ext)
        redirect_to new_import_path, alert: t("imports.create.invalid_document_file_type")
        return
      end

      if file.size > Import::UPLOAD_WARNING_SIZE && !allow_large_upload
        redirect_to new_import_path, alert: t("imports.create.document_file_too_large", max_size: Import::UPLOAD_WARNING_SIZE / 1.megabyte)
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

    def selected_document_account
      account_id = import_params[:account_id]
      return if account_id.blank?

      account = accessible_accounts.find_by(id: account_id)
      unless account
        redirect_to new_import_path, alert: t("imports.update.invalid_account", default: "Account not found.")
        return
      end

      account
    end

    def create_multiple_sure_imports(files)
      imported_count = 0
      errors = []

      files.each do |file|
        filename = file.original_filename.to_s
        if file.size > SureImport.max_ndjson_size
          errors << "#{filename}: #{t('imports.create.file_too_large', max_size: SureImport.max_ndjson_size / 1.megabyte)}"
          next
        end
        unless File.extname(filename).downcase.in?(%w[.ndjson .json])
          errors << "#{filename}: #{t('imports.create.invalid_ndjson_file_type')}"
          next
        end

        content = file.read
        file.rewind
        unless SureImport.valid_ndjson_first_line?(content)
          errors << "#{filename}: #{t('imports.create.invalid_ndjson_file_type')}"
          next
        end

        import = Current.family.imports.create!(type: "SureImport", date_format: Current.family.date_format)
        import.ndjson_file.attach(io: StringIO.new(content), filename: filename, content_type: file.content_type)
        import.sync_ndjson_rows_count!
        imported_count += 1
      rescue StandardError => error
        Rails.logger.warn("Sure export batch import failed for #{filename}: #{error.class}: #{error.message}")
        errors << "#{filename}: #{t('imports.create.invalid_ndjson_file_type')}"
      end

      if imported_count.positive?
        redirect_to imports_path, notice: t("imports.create.ndjson_uploaded_many", count: imported_count), alert: errors.presence&.join("\n")
      else
        redirect_to new_import_path, alert: errors.presence&.join("\n") || t("imports.create.invalid_ndjson_file_type")
      end
    end

    def create_multiple_csv_imports(files)
      requested_type = requested_import_type.to_s
      requested_type = "TransactionImport" unless requested_type.in?(csv_import_types)
      account_id = import_params[:account_id]
      account = accessible_accounts.find_by(id: account_id) if account_id.present?
      if account_id.present? && account.blank?
        redirect_to new_import_path, alert: t("imports.update.invalid_account", default: "Account not found.")
        return
      end

      imported = []
      errors = []
      files.each do |file|
        filename = file.original_filename.to_s
        if file.size > Import::MAX_CSV_SIZE
          errors << "#{filename}: #{t('imports.create.file_too_large', max_size: Import::MAX_CSV_SIZE / 1.megabyte)}"
          next
        end
        unless Import::ALLOWED_CSV_MIME_TYPES.include?(file.content_type)
          errors << "#{filename}: #{t('imports.create.invalid_file_type')}"
          next
        end

        content = file.read
        file.rewind
        next_type = requested_type
        if requested_type == "TransactionImport"
          next_type = Import::CsvFormat.import_type(selection: params.dig(:import, :csv_format), content: content)
        end
        unless Import.parse_csv_str(content).headers.present? && Import.parse_csv_str(content).any?
          errors << "#{filename}: #{t('import.uploads.show.csv_invalid', default: 'Must be valid CSV with headers and at least one row of data')}"
          next
        end

        import = Current.family.imports.create!(type: next_type, account: account, date_format: Current.family.date_format)
        attributes = { raw_file_str: content }
        attributes.merge!(Import::CsvFormat.default_column_mappings(next_type)) if next_type != requested_type
        import.update!(attributes)
        imported << import
      rescue CSV::MalformedCSVError => error
        errors << "#{filename}: #{t('import.uploads.show.csv_invalid', default: 'Must be valid CSV with headers and at least one row of data')}"
      rescue StandardError => error
        Rails.logger.warn("CSV batch import failed for #{filename}: #{error.class}: #{error.message}")
        errors << "#{filename}: #{t('imports.create.invalid_file_type')}"
      end

      if imported.any?
        redirect_to imports_path, notice: t("imports.create.csv_uploaded_many", count: imported.size), alert: errors.presence&.join("\n")
      else
        redirect_to new_import_path, alert: errors.presence&.join("\n") || t("imports.create.invalid_file_type")
      end
    end

    def document_upload_supported_extensions
      adapter = VectorStore.adapter
      return [] unless adapter

      adapter.supported_extensions.map(&:downcase).uniq.sort
    end

    def document_upload_request?
      requested_import_type == "DocumentImport"
    end

    def sure_import_request?
      requested_import_type == "SureImport"
    end

    def requested_import_type
      case params.dig(:import, :file_format)
      when "csv"
        params.dig(:import, :import_kind).presence || "TransactionImport"
      when "document"
        "DocumentImport"
      when "qif"
        "QifImport"
      when "sure"
        "SureImport"
      else
        params.dig(:import, :type)
      end
    end

    def csv_import_types
      %w[TransactionImport TradeImport AccountImport CategoryImport MerchantImport RuleImport MintImport ActualImport YnabImport]
    end

    def import_file_format(import)
      case import.type
      when "QifImport" then "qif"
      when "SureImport" then "sure"
      else "csv"
      end
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
