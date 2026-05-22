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
    elsif csv_valid?(csv_str)
      @import.account = import_account_id.present? ? accessible_accounts.find(import_account_id) : nil
      @import.assign_attributes(raw_file_str: csv_str, col_sep: upload_params[:col_sep])
      @import.save!(validate: false)

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

      if uploaded.size > SureImport::MAX_NDJSON_SIZE
        flash.now[:alert] = t("imports.create.file_too_large", max_size: SureImport::MAX_NDJSON_SIZE / 1.megabyte)
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

    def handle_qif_upload
      unless QifParser.valid?(csv_str)
        flash.now[:alert] = "Must be a valid QIF file"
        render :show, status: :unprocessable_entity and return
      end

      unless import_account_id.present?
        flash.now[:alert] = "Please select an account for the QIF import"
        render :show, status: :unprocessable_entity and return
      end

      ActiveRecord::Base.transaction do
        @import.account = accessible_accounts.find(import_account_id)
        @import.raw_file_str = QifParser.normalize_encoding(csv_str)
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
      params.require(:import).permit(:raw_file_str, :import_file, :ndjson_file, :col_sep)
    end

    def import_account_id
      params.require(:import).permit(:account_id)[:account_id]
    end
end
