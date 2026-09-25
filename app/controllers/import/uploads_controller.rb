class Import::UploadsController < ApplicationController
  layout "imports"

  before_action :set_import

  def show
  end

  def sample_csv
    send_data @import.csv_template.to_csv,
      filename: "#{@import.type.underscore.split('_').first}_sample.csv",
      type: "text/csv",
      disposition: "attachment"
  end

  def update
    if @import.is_a?(QifImport)
      handle_qif_upload
    elsif @import.is_a?(SureImport)
      update_sure_import_upload
    elsif csv_uploads.any?
      handle_csv_uploads
    elsif csv_valid?(csv_str)
      save_csv_import!(@import, csv_str)

      redirect_to import_configuration_path(@import, template_hint: true), notice: t("imports.create.csv_uploaded")
    else
      flash.now[:alert] = t("import.uploads.show.csv_invalid", default: "Must be valid CSV with headers and at least one row of data")

      render :show, status: :unprocessable_entity
    end
  end

  private

    def update_sure_import_upload
      uploaded = upload_params[:ndjson_file]
      unless uploaded.present?
        flash.now[:alert] = t("import.uploads.sure_import.ndjson_invalid", default: "Must be valid NDJSON with at least one record")
        render :show, status: :unprocessable_entity
        return
      end

      if uploaded.size > SureImport.max_ndjson_size
        flash.now[:alert] = t("imports.create.file_too_large", max_size: SureImport.max_ndjson_size / 1.megabyte)
        render :show, status: :unprocessable_entity
        return
      end

      content = uploaded.read
      uploaded.rewind

      if ndjson_valid?(content)
        uploaded.rewind
        @import.ndjson_file.attach(uploaded)
        @import.sync_ndjson_rows_count!
        redirect_to import_path(@import), notice: t("imports.create.ndjson_uploaded")
      else
        flash.now[:alert] = t("import.uploads.sure_import.ndjson_invalid", default: "Must be valid NDJSON with at least one record")

        render :show, status: :unprocessable_entity
      end
    end

    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def handle_csv_uploads
      if csv_uploads.any? { |upload| !valid_csv_file?(upload) }
        flash.now[:alert] = t("import.uploads.show.csv_invalid", default: "Must be valid CSV with headers and at least one row of data")
        render :show, status: :unprocessable_entity
        return
      end

      uploads = csv_uploads.map do |upload|
        content = upload.read
        upload.rewind
        [ upload, content ]
      end

      if uploads.any? { |upload, content| upload.size > Import::MAX_CSV_SIZE || content.bytesize > Import::MAX_CSV_SIZE }
        flash.now[:alert] = t("imports.create.file_too_large", max_size: Import::MAX_CSV_SIZE / 1.megabyte)
        render :show, status: :unprocessable_entity
        return
      end

      unless uploads.all? { |_upload, content| csv_valid?(content) }
        flash.now[:alert] = t("import.uploads.show.csv_invalid", default: "Must be valid CSV with headers and at least one row of data")
        render :show, status: :unprocessable_entity
        return
      end

      account = import_account_id.present? ? accessible_accounts.find(import_account_id) : nil
      imports = ActiveRecord::Base.transaction do
        uploads.each_with_index.map do |(file, content), index|
          import = index.zero? ? @import : build_csv_import(account)
          save_csv_import!(import, content, account: account, file: file)
          import
        end
      end

      if uploads_share_format? && imports.length > 1
        session[:same_format_csv_import_ids] = imports.map(&:id)
      else
        session.delete(:same_format_csv_import_ids)
      end

      if uploads.one? || uploads_share_format?
        redirect_to import_configuration_path(imports.first, template_hint: true), notice: t("imports.create.csv_uploaded")
      else
        redirect_to imports_path, notice: t("imports.create.csv_uploaded_many", count: imports.size)
      end
    end

    def build_csv_import(account)
      Current.family.imports.create!(
        type: @import.type,
        account: account,
        date_format: @import.date_format,
        col_sep: upload_params[:col_sep]
      )
    end

    def save_csv_import!(import, content, account: nil, file: nil)
      import.account = account
      import.assign_attributes(
        raw_file_str: content,
        col_sep: upload_params[:col_sep],
        source_filename: file&.original_filename
      )
      import.save!(validate: false)
      if file
        file.rewind
        import.source_file.attach(file)
      end
    end

    def uploads_share_format?
      ActiveModel::Type::Boolean.new.cast(upload_params[:same_format])
    end

    def valid_csv_file?(file)
      file.size <= Import::MAX_CSV_SIZE && Import::ALLOWED_CSV_MIME_TYPES.include?(file.content_type)
    end

    def handle_qif_upload
      unless QifParser.valid?(csv_str)
        flash.now[:alert] = "Must be a valid QIF file"
        render :show, status: :unprocessable_entity and return
      end

      normalized_qif = QifParser.normalize_encoding(csv_str)

      unless import_account_id.present? || QifParser.parse_accounts(normalized_qif).any?
        flash.now[:alert] = t(".qif_account_required")
        render :show, status: :unprocessable_entity and return
      end

      ActiveRecord::Base.transaction do
        @import.account = accessible_accounts.find(import_account_id) if import_account_id.present?
        @import.raw_file_str = normalized_qif
        @import.save!(validate: false)
        @import.generate_rows_from_csv
        @import.sync_mappings
      end

      redirect_to import_qif_category_selection_path(@import), notice: t(".qif_uploaded")
    end

    def csv_uploads
      uploads = upload_params[:import_files].presence || upload_params[:import_file]
      Array(uploads).filter_map do |upload|
        upload if upload.respond_to?(:read) && upload.respond_to?(:original_filename)
      end
    end

    def csv_str
      @csv_str ||= csv_uploads.first&.read || upload_params[:raw_file_str]
    end

    def csv_valid?(str)
      begin
        csv = Import.parse_csv_str(str, col_sep: upload_params[:col_sep])
        return false if csv.headers.empty?
        return false if csv.count == 0
        true
      rescue CSV::MalformedCSVError
        false
      end
    end

    def ndjson_valid?(str)
      return false if str.blank?

      # Check at least first line is valid NDJSON
      first_line = str.lines.first&.strip
      return false if first_line.blank?

      begin
        record = JSON.parse(first_line)
        record.key?("type") && record.key?("data")
      rescue JSON::ParserError
        false
      end
    end

    def upload_params
      params.require(:import).permit(:raw_file_str, :import_file, :ndjson_file, :col_sep, :same_format, import_file: [], import_files: [])
    end

    def import_account_id
      params.require(:import).permit(:account_id)[:account_id]
    end
end
