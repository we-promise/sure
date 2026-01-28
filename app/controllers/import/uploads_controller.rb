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
    if @import.type == "BulkImport"
      update_bulk_import
    else
      update_csv_import
    end
  end

  private
    def update_csv_import
      if csv_valid?(csv_str)
        @import.account = Current.family.accounts.find_by(id: params.dig(:import, :account_id))
        @import.assign_attributes(raw_file_str: csv_str, col_sep: upload_params[:col_sep])
        @import.save!(validate: false)

        redirect_to import_configuration_path(@import, template_hint: true), notice: t("imports.create.csv_uploaded")
      else
        flash.now[:alert] = t("import.uploads.show.csv_invalid", default: "Must be valid CSV with headers and at least one row of data")

        render :show, status: :unprocessable_entity
      end
    end

    def update_bulk_import
      if ndjson_valid?(file_str)
        @import.assign_attributes(raw_file_str: file_str)
        @import.save!(validate: false)
        @import.generate_rows_from_csv # Sets the row count

        redirect_to import_confirm_path(@import), notice: t("imports.create.ndjson_uploaded")
      else
        flash.now[:alert] = t("import.uploads.bulk_import.ndjson_invalid", default: "Must be valid NDJSON with at least one record")

        render :show, status: :unprocessable_entity
      end
    end

    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def file_str
      @file_str ||= upload_params[:csv_file]&.read || upload_params[:raw_file_str]
    end

    def csv_str
      @csv_str ||= file_str
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
      params.require(:import).permit(:raw_file_str, :csv_file, :col_sep)
    end
end
