require "digest"
require "stringio"
require "zip"

module TaxWorkbook
  class Parser
    class UserDataError < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = Array(errors)
        super(@errors.first&.fetch("message", "Invalid tax workbook") || "Invalid tax workbook")
      end
    end

    ROW_COUNT_SHEETS = {
      "gst_outward_lines" => :gst_outward_lines,
      "gst_3b_summary" => :gst3b_summaries,
      "gst_hsn_summary" => :gst_hsn_summaries,
      "tds_challans" => :tds_challans,
      "tds_deductions" => :tds_deductions
    }.freeze

    def initialize(family:, uploaded_by:, file:)
      @family = family
      @uploaded_by = uploaded_by
      @file = file
      @value_parser = ValueParser.new
      @errors = []
    end

    def call
      @errors = []
      import = nil
      tempfile = nil

      content = read_file!
      import = build_import(content)

      unless import.save
        errors = import_validation_errors(import)
        import.validation_errors = errors if import.respond_to?(:validation_errors=)
        return ImportResult.new(false, import, errors)
      end

      attach_source_file!(import, content)

      tempfile = write_tempfile(content)
      reader = SheetReader.new(tempfile.path)

      validate_template!(reader)
      meta_attributes = parse_meta!(reader.rows("meta"))
      import.update!(meta_attributes.merge(status: "validated", validation_errors: [], row_counts: {}))

      ActiveRecord::Base.transaction do
        import.update!(status: "importing")

        create_gst_outward_lines!(import, reader.rows("gst_outward_lines"))
        create_gst3b_summaries!(import, reader.rows("gst_3b_summary"))
        create_gst_hsn_summaries!(import, reader.rows("gst_hsn_summary"))
        challans_by_ref = create_tds_challans!(import, reader.rows("tds_challans"))
        create_tds_deductions!(import, reader.rows("tds_deductions"), challans_by_ref)

        import.update!(status: "complete", row_counts: build_row_counts(import), validation_errors: [])
      end

      ImportResult.new(true, import.reload, [])
    rescue UserDataError => error
      failure_result(import, error.errors)
    rescue Zip::Error => error
      failure_result(import, [ error_payload(message: "Workbook could not be read as XLSX", value: error.message) ])
    rescue ActiveRecord::RecordNotUnique => error
      failure_result(import, [ error_payload(sheet: "import", column: "checksum", message: "Workbook has already been imported for this family", value: error.message) ])
    ensure
      tempfile&.close!
    end

    private
      attr_reader :family, :uploaded_by, :file, :value_parser

      def read_file!
        raise UserDataError.new([ error_payload(sheet: "import", column: "file", message: "Choose an XLSX file") ]) unless file&.respond_to?(:read)

        if file.respond_to?(:size) && file.size.to_i > TaxWorkbookImport::MAX_FILE_SIZE
          raise UserDataError.new([ error_payload(sheet: "import", column: "file", message: "File is too large") ])
        end

        content = file.read
        file.rewind if file.respond_to?(:rewind)

        raise UserDataError.new([ error_payload(sheet: "import", column: "file", message: "File is empty") ]) if content.blank?

        content
      end

      def build_import(content)
        family.tax_workbook_imports.build(
          uploaded_by: uploaded_by,
          filename: file.respond_to?(:original_filename) ? file.original_filename.to_s : nil,
          content_type: file.respond_to?(:content_type) ? file.content_type.to_s : nil,
          byte_size: content.bytesize,
          checksum: Digest::SHA256.hexdigest(content),
          template_version: Template::VERSION,
          status: "pending"
        )
      end

      def attach_source_file!(import, content)
        import.source_file.attach(
          io: StringIO.new(content),
          filename: import.filename,
          content_type: import.content_type
        )
      end

      def write_tempfile(content)
        tempfile = Tempfile.new([ "tax-workbook", ".xlsx" ])
        tempfile.binmode
        tempfile.write(content)
        tempfile.rewind
        tempfile
      end

      def validate_template!(reader)
        missing_sheets = Template::SHEET_NAMES - reader.sheet_names
        missing_sheets.each do |sheet_name|
          add_error(sheet: sheet_name, row: 1, message: "Missing required sheet")
        end

        (Template::SHEET_NAMES - missing_sheets).each do |sheet_name|
          next if reader.headers(sheet_name) == Template.headers_for(sheet_name)

          add_error(
            sheet: sheet_name,
            row: 1,
            value: {
              "expected" => Template.headers_for(sheet_name),
              "actual" => reader.headers(sheet_name)
            },
            message: "Headers do not match template"
          )
        end

        raise UserDataError.new(@errors) if @errors.any?
      end

      def parse_meta!(rows)
        row = rows.first
        raise UserDataError.new([ error_payload(sheet: "meta", row: 2, message: "Meta sheet must contain at least one data row") ]) if row.blank?

        {
          entity_name: row.fetch("entity_name").to_s.strip,
          gstin: value_parser.gstin(row.fetch("gstin")),
          tan: value_parser.tan(row.fetch("tan")),
          fy: row.fetch("fy").to_s.strip,
          tax_period_month: value_parser.month(row.fetch("tax_period_month")),
          tax_period_quarter: value_parser.quarter(row.fetch("tax_period_quarter")),
          metadata: {
            "return_type" => row["return_type"].to_s.strip.presence,
            "source_system" => row["source_system"].to_s.strip.presence,
            "source_file_name" => row["source_file_name"].to_s.strip.presence
          }.compact
        }
      rescue KeyError, ArgumentError => error
        raise row_error!(
          sheet: "meta",
          row: row&.fetch("source_row_number", 2) || 2,
          message: error.message
        )
      end

      def create_gst_outward_lines!(import, rows)
        rows.each do |row|
          import.gst_outward_lines.create!(
            family: family,
            source_row_number: row.fetch("source_row_number"),
            tax_period_month: import.tax_period_month,
            gstin: import.gstin,
            gstr1_table_code: row.fetch("gstr1_table_code").to_s.strip,
            invoice_no: row.fetch("invoice_no").to_s.strip,
            invoice_date: value_parser.date(row.fetch("invoice_date")),
            recipient_gstin_or_uin: normalized_text(row["recipient_gstin_or_uin"]),
            place_of_supply_state: normalized_text(row["place_of_supply_state"]),
            hsn_code: normalized_text(row["hsn_code"]),
            rate_pct: optional_decimal(row["rate_pct"]),
            taxable_value: value_parser.decimal(row["taxable_value"]),
            igst: value_parser.decimal(row["igst"]),
            cgst: value_parser.decimal(row["cgst"]),
            sgst_ugst: value_parser.decimal(row["sgst_ugst"]),
            cess: value_parser.decimal(row["cess"]),
            is_reverse_charge: value_parser.boolean(row["is_reverse_charge"]),
            is_export: value_parser.boolean(row["is_export"]),
            is_ecommerce_tcs: value_parser.boolean(row["is_ecommerce_tcs"]),
            is_credit_note: value_parser.boolean(row["is_credit_note"]),
            is_debit_note: value_parser.boolean(row["is_debit_note"])
          )
        rescue KeyError, ArgumentError, ActiveRecord::RecordInvalid => error
          raise row_error!(sheet: "gst_outward_lines", row: row["source_row_number"], message: record_message(error))
        end
      end

      def create_gst3b_summaries!(import, rows)
        rows.each do |row|
          import.gst3b_summaries.create!(
            family: family,
            source_row_number: row.fetch("source_row_number"),
            tax_period_month: import.tax_period_month,
            gstin: import.gstin,
            section_code: row.fetch("section_code").to_s.strip,
            taxable_value: value_parser.decimal(row["taxable_value"]),
            igst: value_parser.decimal(row["igst"]),
            cgst: value_parser.decimal(row["cgst"]),
            sgst_ugst: value_parser.decimal(row["sgst_ugst"]),
            cess: value_parser.decimal(row["cess"]),
            interest: value_parser.decimal(row["interest"]),
            late_fee: value_parser.decimal(row["late_fee"])
          )
        rescue KeyError, ArgumentError, ActiveRecord::RecordInvalid => error
          raise row_error!(sheet: "gst_3b_summary", row: row["source_row_number"], message: record_message(error))
        end
      end

      def create_gst_hsn_summaries!(import, rows)
        rows.each do |row|
          import.gst_hsn_summaries.create!(
            family: family,
            source_row_number: row.fetch("source_row_number"),
            tax_period_month: import.tax_period_month,
            gstin: import.gstin,
            hsn_code: row.fetch("hsn_code").to_s.strip,
            description: normalized_text(row["description"]),
            uqc: normalized_text(row["uqc"]),
            quantity: value_parser.decimal(row["quantity"]),
            taxable_value: value_parser.decimal(row["taxable_value"]),
            igst: value_parser.decimal(row["igst"]),
            cgst: value_parser.decimal(row["cgst"]),
            sgst_ugst: value_parser.decimal(row["sgst_ugst"]),
            cess: value_parser.decimal(row["cess"]),
            bucket: row.fetch("bucket").to_s.strip.upcase
          )
        rescue KeyError, ArgumentError, ActiveRecord::RecordInvalid => error
          raise row_error!(sheet: "gst_hsn_summary", row: row["source_row_number"], message: record_message(error))
        end
      end

      def create_tds_challans!(import, rows)
        rows.each_with_object({}) do |row, challans_by_ref|
          challan = import.tds_challans.create!(
            family: family,
            source_row_number: row.fetch("source_row_number"),
            tax_period_quarter: import.tax_period_quarter,
            tan: import.tan,
            challan_ref: row.fetch("challan_ref").to_s.strip,
            mode_of_deposit: normalized_text(row["mode_of_deposit"]),
            bsr_code_or_receipt_no: normalized_text(row["bsr_code_or_receipt_no"]),
            challan_serial_no_or_ddo_serial_no: normalized_text(row["challan_serial_no_or_ddo_serial_no"]),
            deposit_date: optional_date(row["deposit_date"]),
            minor_head: normalized_text(row["minor_head"]),
            tax: value_parser.decimal(row["tax"]),
            interest: value_parser.decimal(row["interest"]),
            fee: value_parser.decimal(row["fee"]),
            penalty: value_parser.decimal(row["penalty"]),
            others: value_parser.decimal(row["others"]),
            total_amount: value_parser.decimal(row["total_amount"])
          )

          challans_by_ref[challan.challan_ref] = challan
        rescue KeyError, ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
          raise row_error!(sheet: "tds_challans", row: row["source_row_number"], message: record_message(error))
        end
      end

      def create_tds_deductions!(import, rows, challans_by_ref)
        rows.each do |row|
          challan_ref = normalized_text(row["challan_ref"])
          challan = challans_by_ref[challan_ref]

          if challan_ref.present? && challan.blank?
            raise row_error!(sheet: "tds_deductions", row: row["source_row_number"], column: "challan_ref", value: challan_ref, message: "must match a challan in the same import")
          end

          import.tds_deductions.create!(
            family: family,
            tax_workbook_import: import,
            tds_challan: challan,
            source_row_number: row.fetch("source_row_number"),
            tax_period_month: import.tax_period_month,
            tax_period_quarter: import.tax_period_quarter,
            deductor_tan: value_parser.tan(row.fetch("deductor_tan")),
            deductee_pan_or_aadhaar: parse_deductee_identifier(row.fetch("deductee_pan_or_aadhaar")),
            deductee_name: normalized_text(row["deductee_name"]),
            section_code: row.fetch("section_code").to_s.strip,
            booking_date: optional_date(row["booking_date"]),
            payment_date: optional_date(row["payment_date"]),
            amount_paid: value_parser.decimal(row["amount_paid"]),
            tds_rate_pct: optional_decimal(row["tds_rate_pct"]),
            tds_amount: value_parser.decimal(row["tds_amount"]),
            surcharge: value_parser.decimal(row["surcharge"]),
            cess: value_parser.decimal(row["cess"]),
            challan_ref: challan_ref,
            resident_status: normalized_text(row["resident_status"])
          )
        rescue KeyError, ArgumentError, ActiveRecord::RecordInvalid => error
          raise row_error!(sheet: "tds_deductions", row: row["source_row_number"], message: record_message(error))
        end
      end

      def parse_deductee_identifier(value)
        normalized = normalized_text(value)
        return if normalized.blank?
        return normalized if normalized.match?(/\A\d{12}\z/)

        value_parser.pan(normalized)
      rescue ArgumentError
        raise ArgumentError, "must be a 10-character PAN or 12-digit Aadhaar"
      end

      def optional_date(value)
        return if value.blank?

        value_parser.date(value)
      end

      def optional_decimal(value)
        return if value.blank?

        value_parser.decimal(value)
      end

      def normalized_text(value)
        value.to_s.strip.presence
      end

      def build_row_counts(import)
        ROW_COUNT_SHEETS.transform_values do |association_name|
          import.public_send(association_name).size
        end
      end

      def import_validation_errors(import)
        import.errors.map do |error|
          error_payload(
            sheet: "import",
            column: error.attribute.to_s,
            value: safe_attribute_value(import, error.attribute),
            message: error.full_message
          )
        end
      end

      def safe_attribute_value(import, attribute)
        return if attribute == :base

        import.public_send(attribute)
      rescue NoMethodError
        nil
      end

      def record_message(error)
        case error
        when ActiveRecord::RecordInvalid
          error.record.errors.full_messages.to_sentence
        else
          error.message
        end
      end

      def row_error!(sheet:, row:, message:, column: nil, value: nil)
        payload = error_payload(sheet: sheet, row: row, column: column, value: value, message: message)
        @errors << payload
        UserDataError.new([ payload ])
      end

      def add_error(sheet:, row:, message:, column: nil, value: nil)
        @errors << error_payload(sheet: sheet, row: row, column: column, value: value, message: message)
      end

      def error_payload(sheet: nil, row: nil, column: nil, value: nil, message:)
        {
          "sheet" => sheet,
          "row" => row,
          "column" => column,
          "value" => value,
          "message" => message
        }.compact
      end

      def failure_result(import, errors)
        if import&.persisted?
          import.update!(status: "failed", validation_errors: errors, row_counts: {})
          import.reload
        elsif import
          import.status = "failed"
          import.validation_errors = errors
        end

        ImportResult.new(false, import, errors)
      end
  end
end
