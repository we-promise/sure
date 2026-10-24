require "csv"
require "stringio"
require "zip"
require "nokogiri"

module Icost
  # Reads values, never evaluates formulas or follows links in an uploaded file.
  class FileParser
    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    MAX_FILE_BYTES = 10 * 1024 * 1024
    MAX_XML_BYTES = 16 * 1024 * 1024
    MAX_EXPANDED_BYTES = 32 * 1024 * 1024
    MAX_ZIP_ENTRIES = 256
    MAX_ROWS = 10_000
    MAX_COLUMNS = 256
    MAX_CELL_BYTES = 32_768
    SPREADSHEET_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    RELATIONSHIP_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    PACKAGE_NS = "http://schemas.openxmlformats.org/package/2006/relationships"

    def self.call(bytes:, filename:)
      new(bytes, filename).call
    end

    def initialize(bytes, filename)
      @bytes = bytes
      @filename = filename
    end

    def call
      fail_with("file_too_large") if @bytes.bytesize > MAX_FILE_BYTES
      fail_with("empty_file") if @bytes.empty?

      case File.extname(@filename).downcase
      when ".csv" then parse_csv
      when ".xlsx" then parse_xlsx
      else fail_with("unsupported_file_type")
      end
    rescue CSV::MalformedCSVError
      fail_with("invalid_csv")
    rescue Zip::Error, Nokogiri::XML::SyntaxError, ArgumentError, EncodingError
      fail_with("invalid_file")
    end

    private

      def parse_csv
        text = @bytes.dup.force_encoding(Encoding::UTF_8)
        fail_with("invalid_encoding") unless text.valid_encoding?
        fail_with("invalid_file") if text.include?("\0")
        text = text.delete_prefix("\uFEFF")
        records = []
        CSV.new(StringIO.new(text), field_size_limit: MAX_CELL_BYTES).each.with_index(1) do |values, number|
          validate_values(values)
          fail_with("too_many_rows") if number > MAX_ROWS + 1
          records << { row_number: number, values: values } unless empty_row?(values)
        end
        assemble(records, "CSV")
      end

      def parse_xlsx
        Zip::File.open_buffer(StringIO.new(@bytes)) do |archive|
          entries = archive.entries
          fail_with("archive_too_large") if entries.size > MAX_ZIP_ENTRIES || entries.sum(&:size) > MAX_EXPANDED_BYTES
          fail_with("duplicate_archive_entry") if entries.map(&:name).uniq.size != entries.size
          fail_with("encrypted_archive") if entries.any?(&:encrypted?)
          fail_with("unsafe_archive_path") if entries.any? { |entry| unsafe_path?(entry.name) }

          workbook = read_xml(archive, "xl/workbook.xml")
          sheets = workbook.xpath("/s:workbook/s:sheets/s:sheet", "s" => SPREADSHEET_NS)
          fail_with("missing_worksheet") if sheets.empty?
          # Multiple ledgers must be reviewed independently, not silently ignored.
          fail_with("multiple_worksheets") if sheets.size > 1
          sheet = sheets.first
          relationships = read_xml(archive, "xl/_rels/workbook.xml.rels")
          id = sheet.attribute_with_ns("id", RELATIONSHIP_NS)&.value
          relation = relationships.xpath("/r:Relationships/r:Relationship", "r" => PACKAGE_NS).find { |item| item["Id"] == id }
          fail_with("invalid_worksheet_relationship") unless relation && relation["Type"] == "#{RELATIONSHIP_NS}/worksheet" && relation["TargetMode"] != "External"
          target = relation["Target"].to_s
          fail_with("unsafe_archive_path") if unsafe_path?(target.delete_prefix("/"))
          sheet_path = target.start_with?("/") ? target.delete_prefix("/") : "xl/#{target}"
          fail_with("invalid_worksheet_relationship") unless sheet_path.start_with?("xl/worksheets/")

          shared_strings = read_shared_strings(archive)
          worksheet = read_xml(archive, sheet_path)
          return parse_worksheet(worksheet, shared_strings, sheet["name"].to_s)
        end
      end

      def parse_worksheet(worksheet, shared_strings, sheet_name)
        records = []
        seen_rows = {}
        worksheet.xpath("/s:worksheet/s:sheetData/s:row", "s" => SPREADSHEET_NS).each.with_index(1) do |row, fallback_number|
          number = integer(row["r"] || fallback_number.to_s)
          fail_with("too_many_rows") if number > MAX_ROWS + 1
          fail_with("invalid_row_number") if number < 1 || seen_rows[number]
          seen_rows[number] = true
          values = []
          seen_columns = {}
          row.xpath("s:c", "s" => SPREADSHEET_NS).each.with_index do |cell, fallback_column|
            reference = cell["r"]
            if reference
              match = /\A([A-Z]+)([1-9]\d*)\z/.match(reference)
              fail_with("invalid_cell_reference") unless match && integer(match[2]) == number
              column = match[1].each_byte.reduce(0) { |index, character| index * 26 + character - 64 } - 1
            else
              column = fallback_column
            end
            fail_with("too_many_columns") if column >= MAX_COLUMNS
            fail_with("duplicate_cell") if seen_columns[column]
            seen_columns[column] = true
            fail_with("formula_not_supported") if cell.at_xpath("s:f", "s" => SPREADSHEET_NS)
            values[column] = cell_value(cell, shared_strings)
          end
          validate_values(values)
          records << { row_number: number, values: values } unless empty_row?(values)
        end
        fail_with("unordered_rows") unless records.map { |record| record[:row_number] } == records.map { |record| record[:row_number] }.sort
        assemble(records, sheet_name)
      end

      def cell_value(cell, shared_strings)
        value = cell.at_xpath("s:v", "s" => SPREADSHEET_NS)&.text
        case cell["t"]
        when "s"
          index = integer(value)
          fail_with("invalid_shared_string") unless index >= 0 && index < shared_strings.size
          shared_strings[index]
        when "inlineStr"
          cell.xpath("s:is/s:t | s:is/s:r/s:t", "s" => SPREADSHEET_NS).map(&:text).join
        when "b"
          fail_with("invalid_boolean") unless %w[0 1].include?(value)
          value == "1"
        when "e"
          fail_with("cell_error")
        when nil, "n", "str", "d"
          value
        else
          fail_with("unsupported_cell_type")
        end
      end

      def read_shared_strings(archive)
        return [] unless archive.find_entry("xl/sharedStrings.xml")

        read_xml(archive, "xl/sharedStrings.xml").xpath("/s:sst/s:si", "s" => SPREADSHEET_NS).map do |item|
          value = item.xpath("s:t | s:r/s:t", "s" => SPREADSHEET_NS).map(&:text).join
          fail_with("cell_too_large") if value.bytesize > MAX_CELL_BYTES
          value
        end
      end

      def read_xml(archive, path)
        entry = archive.find_entry(path)
        fail_with("missing_workbook_part") unless entry
        fail_with("archive_too_large") if entry.size > MAX_XML_BYTES
        xml = entry.get_input_stream { |stream| stream.read(MAX_XML_BYTES + 1) }
        fail_with("archive_too_large") if xml.bytesize > MAX_XML_BYTES
        fail_with("xml_doctype_not_supported") if xml.match?(/<!DOCTYPE/i)
        document = Nokogiri::XML(xml) { |config| config.strict.nonet }
        fail_with("xml_doctype_not_supported") if document.internal_subset || document.external_subset
        document
      end

      def unsafe_path?(path)
        path.start_with?("/") || path.include?("\\") || path.split("/").include?("..") || path.include?("\0")
      end

      def validate_values(values)
        fail_with("too_many_columns") if values.size > MAX_COLUMNS
        fail_with("cell_too_large") if values.any? { |value| value.is_a?(String) && value.bytesize > MAX_CELL_BYTES }
      end

      def assemble(records, sheet_name)
        fail_with("empty_file") if records.empty?
        header = records.shift
        headers = header[:values].map { |value| value.nil? ? "" : value.to_s }
        fail_with("missing_headers") if headers.all?(&:empty?)
        fail_with("missing_data") if records.empty?
        { headers: headers, sheet_name: sheet_name, rows: records }
      end

      def empty_row?(values)
        values.all? { |value| value.nil? || value == "" }
      end

      def integer(value)
        fail_with("invalid_integer") unless /\A\d+\z/.match?(value.to_s)
        value.to_i
      end

      def fail_with(code)
        raise Error, code
      end
  end
end
