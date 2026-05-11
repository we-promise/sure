# frozen_string_literal: true

class Import::Preflight
  Response = Struct.new(:status, :payload, keyword_init: true)

  class PreflightError < StandardError
    attr_reader :status, :payload

    def initialize(response)
      @status = response.status
      @payload = response.payload
      super(response.payload[:message])
    end
  end

  CONFIG_PARAM_KEYS = %i[
    date_col_label
    amount_col_label
    name_col_label
    category_col_label
    tags_col_label
    notes_col_label
    account_col_label
    qty_col_label
    ticker_col_label
    price_col_label
    entity_type_col_label
    currency_col_label
    exchange_operating_mic_col_label
    date_format
    number_format
    signage_convention
    col_sep
    amount_type_strategy
    amount_type_inflow_value
    rows_to_skip
  ].freeze

  PARAM_KEYS = ([
    :type,
    :account_id,
    :file,
    :raw_file_content
  ] + CONFIG_PARAM_KEYS).freeze

  UNSUPPORTED_PREFLIGHT_IMPORT_TYPES = %w[PdfImport QifImport].freeze
  IMPORT_TYPES = (Import::TYPES - UNSUPPORTED_PREFLIGHT_IMPORT_TYPES).freeze

  def initialize(family:, params:)
    @family = family
    @params = params.to_h.symbolize_keys
  end

  def call
    type = preflight_import_type
    return invalid_import_type_response unless type

    type == "SureImport" ? sure_import_response : csv_import_response(type)
  rescue PreflightError => e
    Response.new(status: e.status, payload: e.payload)
  end

  private
    attr_reader :family, :params

    def preflight_import_type
      type = params[:type].to_s
      return "TransactionImport" if type.blank?

      type if IMPORT_TYPES.include?(type)
    end

    def invalid_import_type_response
      Response.new(
        status: :unprocessable_entity,
        payload: {
          error: "invalid_import_type",
          message: "type must be one of: #{IMPORT_TYPES.join(', ')}"
        }
      )
    end

    def sure_import_response
      upload_attributes = sure_import_upload_attributes
      return missing_sure_content_response unless upload_attributes

      content, filename, content_type = upload_attributes
      Response.new(
        status: :ok,
        payload: {
          data: sure_import_preflight_payload(content, filename, content_type)
        }
      )
    end

    def csv_import_response(type)
      upload_attributes = csv_upload_attributes
      return missing_csv_content_response unless upload_attributes

      content, filename, content_type = upload_attributes
      import = family.imports.build(import_config_params.merge(type: type, raw_file_str: content))
      import.account = preflight_account if params[:account_id].present?
      apply_import_defaults(import)

      return unsupported_import_type_response unless import.requires_csv_workflow?

      unless import.valid?
        return Response.new(
          status: :ok,
          payload: {
            data: csv_preflight_payload(
              import: import,
              type: type,
              filename: filename,
              content_type: content_type,
              content: content,
              parsed_rows_count: 0,
              csv_headers: [],
              missing_required_headers: [],
              errors: validation_errors(import),
              warnings: []
            )
          }
        )
      end

      csv_content = csv_content_for(import, content)
      csv = Import.parse_csv_str(csv_content, col_sep: import.col_sep)
      parsed_rows_count = csv.length
      csv_headers = Array(csv.headers).compact
      missing_required_headers = missing_required_headers(import, csv_headers)
      errors = validation_errors(import)

      if missing_required_headers.any?
        errors << {
          code: "missing_required_headers",
          message: "Missing required columns: #{missing_required_headers.join(', ')}"
        }
      end

      if parsed_rows_count.zero?
        errors << {
          code: "no_data_rows",
          message: "No data rows were found."
        }
      end

      warnings = []
      warnings << "Row count exceeds this import type's publish limit." if parsed_rows_count > import.max_row_count

      Response.new(
        status: :ok,
        payload: {
          data: csv_preflight_payload(
            import: import,
            type: type,
            filename: filename,
            content_type: content_type,
            content: content,
            parsed_rows_count: parsed_rows_count,
            csv_headers: csv_headers,
            missing_required_headers: missing_required_headers,
            errors: errors,
            warnings: warnings
          )
        }
      )
    end

    def import_config_params
      params.slice(*CONFIG_PARAM_KEYS)
    end

    def preflight_account
      raise ActiveRecord::RecordNotFound unless Api::V1::BaseController.valid_uuid?(params[:account_id])

      family.accounts.find(params[:account_id])
    end

    def csv_upload_attributes
      if params[:file].present?
        csv_file_upload_attributes(params[:file])
      elsif params[:raw_file_content].present?
        csv_raw_content_attributes(params[:raw_file_content].to_s)
      end
    end

    def csv_file_upload_attributes(file)
      raise_response csv_file_too_large_response if file.size > Import.max_csv_size
      raise_response invalid_csv_file_type_response unless Import::ALLOWED_CSV_MIME_TYPES.include?(file.content_type)

      [
        file.read,
        file.original_filename.presence || "import.csv",
        file.content_type.presence || "text/csv"
      ]
    end

    def csv_raw_content_attributes(content)
      raise_response csv_content_too_large_response if content.bytesize > Import.max_csv_size

      [ content, "import.csv", "text/csv" ]
    end

    def sure_import_upload_attributes
      if params[:file].present?
        sure_import_file_upload_attributes(params[:file])
      elsif params[:raw_file_content].present?
        sure_import_raw_content_attributes(params[:raw_file_content].to_s)
      end
    end

    def sure_import_file_upload_attributes(file)
      raise_response sure_file_too_large_response if file.size > SureImport.max_ndjson_size

      extension = File.extname(file.original_filename.to_s).downcase
      unless SureImport::ALLOWED_NDJSON_CONTENT_TYPES.include?(file.content_type) || extension.in?(%w[.ndjson .json])
        raise_response invalid_sure_file_type_response
      end

      [
        file.read,
        file.original_filename.presence || "sure-import.ndjson",
        file.content_type.presence || "application/x-ndjson"
      ]
    end

    def sure_import_raw_content_attributes(content)
      raise_response sure_content_too_large_response if content.bytesize > SureImport.max_ndjson_size

      [ content, "sure-import.ndjson", "application/x-ndjson" ]
    end

    def sure_import_preflight_payload(content, filename, content_type)
      line_counts = Hash.new(0)
      errors = []
      valid_rows_count = 0
      nonblank_rows_count = 0

      content.each_line.with_index(1) do |line, line_number|
        next if line.strip.blank?

        nonblank_rows_count += 1
        record = JSON.parse(line)

        unless record.is_a?(Hash)
          errors << {
            code: "invalid_ndjson_record",
            message: "Line #{line_number} must be a JSON object."
          }
          next
        end

        if record["type"].blank? || !record.key?("data")
          errors << {
            code: "invalid_ndjson_record",
            message: "Line #{line_number} must include type and data."
          }
          next
        end

        valid_rows_count += 1
        line_counts[record["type"]] += 1
      rescue JSON::ParserError => e
        errors << {
          code: "invalid_json",
          message: "Line #{line_number} is not valid JSON: #{e.message}"
        }
      end

      if nonblank_rows_count.zero?
        errors << {
          code: "no_data_rows",
          message: "No data rows were found."
        }
      end

      entity_counts = SureImport.dry_run_totals_from_line_type_counts(line_counts)
      unsupported_types = line_counts.keys - SureImport.importable_ndjson_types
      warnings = []
      warnings << "No importable records were found." if nonblank_rows_count.positive? && entity_counts.values.sum.zero?
      warnings << "Some records use unsupported types: #{unsupported_types.join(', ')}" if unsupported_types.any?
      warnings << "Row count exceeds this import type's publish limit." if nonblank_rows_count > SureImport.max_row_count

      {
        type: "SureImport",
        valid: errors.empty?,
        content: content_payload(filename, content_type, content),
        stats: {
          rows_count: nonblank_rows_count,
          valid_rows_count: valid_rows_count,
          invalid_rows_count: nonblank_rows_count - valid_rows_count,
          entity_counts: entity_counts,
          record_type_counts: line_counts
        },
        errors: errors,
        warnings: warnings
      }
    end

    def content_payload(filename, content_type, content)
      {
        filename: filename,
        content_type: content_type,
        byte_size: content.bytesize
      }
    end

    def csv_content_for(import, content)
      return content unless import.rows_to_skip.to_i.positive?

      content.lines.drop(import.rows_to_skip.to_i).join
    end

    def apply_import_defaults(import)
      return unless import.is_a?(MintImport)

      MintImport.default_column_mappings.each do |attribute, value|
        import.public_send("#{attribute}=", value) if import.public_send(attribute).blank?
      end
    end

    def validation_errors(import)
      import.errors.full_messages.map { |message| { code: "validation_failed", message: message } }
    end

    def csv_preflight_payload(import:, type:, filename:, content_type:, content:, parsed_rows_count:, csv_headers:, missing_required_headers:, errors:, warnings:)
      {
        type: type,
        valid: errors.empty?,
        content: content_payload(filename, content_type, content),
        stats: {
          rows_count: parsed_rows_count
        },
        headers: csv_headers,
        required_headers: required_header_labels(import),
        missing_required_headers: missing_required_headers,
        errors: errors,
        warnings: warnings
      }
    end

    def required_header_labels(import)
      import.required_column_keys.filter_map do |key|
        import.respond_to?("#{key}_col_label") ? import.public_send("#{key}_col_label").presence || key.to_s : key.to_s
      end
    end

    def missing_required_headers(import, headers)
      normalized_headers = Array(headers).compact.to_h { |header| [ normalized_header(header), header ] }

      required_header_labels(import).reject do |header|
        normalized_headers.key?(normalized_header(header))
      end
    end

    def normalized_header(header)
      header.to_s.strip.downcase.gsub(/\*/, "").gsub(/[\s-]+/, "_")
    end

    def missing_csv_content_response
      Response.new(
        status: :unprocessable_entity,
        payload: {
          error: "missing_content",
          message: "Provide a CSV file or raw_file_content."
        }
      )
    end

    def missing_sure_content_response
      Response.new(
        status: :unprocessable_entity,
        payload: {
          error: "missing_content",
          message: "Provide a Sure NDJSON file or raw_file_content."
        }
      )
    end

    def csv_file_too_large_response
      Response.new(
        status: :unprocessable_entity,
        payload: {
          error: "file_too_large",
          message: "File is too large. Maximum size is #{Import.max_csv_size / 1.megabyte}MB."
        }
      )
    end

    def csv_content_too_large_response
      Response.new(
        status: :unprocessable_entity,
        payload: {
          error: "content_too_large",
          message: "Content is too large. Maximum size is #{Import.max_csv_size / 1.megabyte}MB."
        }
      )
    end

    def invalid_csv_file_type_response
      Response.new(
        status: :unprocessable_entity,
        payload: {
          error: "invalid_file_type",
          message: "Invalid file type. Please upload a CSV file."
        }
      )
    end

    def sure_file_too_large_response
      Response.new(
        status: :unprocessable_entity,
        payload: {
          error: "file_too_large",
          message: "File is too large. Maximum size is #{SureImport.max_ndjson_size / 1.megabyte}MB."
        }
      )
    end

    def sure_content_too_large_response
      Response.new(
        status: :unprocessable_entity,
        payload: {
          error: "content_too_large",
          message: "Content is too large. Maximum size is #{SureImport.max_ndjson_size / 1.megabyte}MB."
        }
      )
    end

    def invalid_sure_file_type_response
      Response.new(
        status: :unprocessable_entity,
        payload: {
          error: "invalid_file_type",
          message: "Invalid file type. Please upload a Sure NDJSON file."
        }
      )
    end

    def raise_response(response)
      raise PreflightError, response
    end

    def unsupported_import_type_response
      Response.new(
        status: :unprocessable_entity,
        payload: {
          error: "unsupported_import_type",
          message: "Preflight supports CSV import types and SureImport."
        }
      )
    end
end
