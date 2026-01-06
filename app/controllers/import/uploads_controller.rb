require "ofx"
require "stringio"

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
    if @import.type == "OfxImport"
      handle_ofx_upload
    else
      handle_csv_upload
    end
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def csv_str
      @csv_str ||= upload_params[:csv_file]&.read || upload_params[:raw_file_str]
    end

    def ofx_str
      @ofx_str ||= upload_params[:ofx_file]&.read
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

    def ofx_valid?(str)
      return false if str.blank?

      parser = OFX(StringIO.new(str))
      statements = parser.statements
      return false if statements.blank?

      statements.any? { |statement| statement.transactions.present? }
    rescue OFX::UnsupportedFileError, Nokogiri::XML::SyntaxError
      false
    end

    def upload_params
      params.require(:import).permit(:raw_file_str, :csv_file, :ofx_file, :col_sep)
    end

    def handle_csv_upload
      if csv_valid?(csv_str)
        @import.account = Current.family.accounts.find_by(id: params.dig(:import, :account_id))
        @import.assign_attributes(raw_file_str: csv_str, col_sep: upload_params[:col_sep])
        @import.save!(validate: false)

        redirect_to import_configuration_path(@import, template_hint: true), notice: "CSV uploaded successfully."
      else
        flash.now[:alert] = "Must be valid CSV with headers and at least one row of data"

        render :show, status: :unprocessable_entity
      end
    end

    def handle_ofx_upload
      unless ofx_valid?(ofx_str)
        flash.now[:alert] = "Must be a valid OFX file with at least one transaction"
        return render :show, status: :unprocessable_entity
      end

      @import.assign_attributes(raw_file_str: ofx_str)

      selected_account = Current.family.accounts.find_by(id: params.dig(:import, :account_id))
      @import.account = selected_account || @import.matching_account

      if @import.account.nil?
        flash.now[:alert] = "Select an account for this OFX file or create a new one."
        return render :show, status: :unprocessable_entity
      end

      @import.save!(validate: false)

      redirect_to import_configuration_path(@import), notice: "OFX uploaded successfully."
    end
end
