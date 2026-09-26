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
    case file_format_selection
    when "qif"
      switch_import_type!("QifImport")
      handle_qif_upload
    when "sure"
      switch_import_type!("SureImport")
      update_sure_import_upload
    when "csv"
      update_csv_upload
    else
      redirect_to import_upload_path(@import), alert: t("imports.create.invalid_file_type")
    end
  end

  private

    def update_csv_upload
      requested_type = upload_params[:import_kind].presence
      requested_type = "TransactionImport" unless requested_type.in?(csv_import_types)
      unless csv_valid?(csv_str)
        flash.now[:alert] = t("import.uploads.show.csv_invalid", default: "Must be valid CSV with headers and at least one row of data")
        render :show, status: :unprocessable_entity
        return
      end

      detected_type = requested_type
      if requested_type == "TransactionImport"
        detected_type = Import::CsvFormat.import_type(
          selection: csv_format_selection,
          content: csv_str,
          col_sep: upload_params[:col_sep].presence || ","
        )
      end
      switch_import_type!(detected_type)

      @import.account = import_account_id.present? ? accessible_accounts.find(import_account_id) : nil
      attributes = { raw_file_str: csv_str, col_sep: upload_params[:col_sep] }

      attributes.merge!(Import::CsvFormat.default_column_mappings(detected_type)) if detected_type != requested_type
      @import.assign_attributes(attributes)
      @import.save!(validate: false)

      redirect_to import_configuration_path(@import, template_hint: true), notice: t("imports.create.csv_uploaded")
    end

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
      @import.csv_format = csv_format_selection
      @file_format = file_format_selection
      @document_upload_extensions = document_upload_supported_extensions
    end

    def file_format_selection
      allowed_formats = %w[csv qif sure]
      allowed_formats << "document" if document_upload_supported_extensions.any?
      (params.dig(:import, :file_format).presence || params[:file_format]).presence_in(allowed_formats) || format_for_import(@import)
    end

    def format_for_import(import)
      case import.type
      when "QifImport" then "qif"
      when "SureImport" then "sure"
      else "csv"
      end
    end

    def document_upload_supported_extensions
      adapter = VectorStore.adapter
      adapter ? adapter.supported_extensions.map(&:downcase).uniq.sort : []
    end

    def csv_import_types
      %w[TransactionImport TradeImport AccountImport CategoryImport MerchantImport RuleImport MintImport ActualImport YnabImport]
    end

    def switch_import_type!(type)
      return if @import.type == type

      previous_import = @import
      @import = Current.family.imports.create!(
        type: type,
        account: previous_import.account,
        date_format: previous_import.date_format || Current.family.date_format
      )
      previous_import.destroy! if previous_import.pending? && !previous_import.data_committed?
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

    def csv_str
      @csv_str ||= upload_params[:import_file]&.read || upload_params[:raw_file_str]
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
      params.require(:import).permit(:raw_file_str, :import_file, :ndjson_file, :col_sep, :csv_format, :file_format, :import_kind)
    end

    def csv_format_selection
      selections = Import::CsvFormat.options.map(&:last)
      (params.dig(:import, :csv_format).presence || params[:csv_format]).presence_in(selections) || "auto"
    end

    def import_account_id
      params.require(:import).permit(:account_id)[:account_id]
    end
end
