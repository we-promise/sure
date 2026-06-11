module TaxWorkbook
  class SheetReader
    def initialize(path)
      @workbook = SimpleXlsxReader.open(path)
    end

    def sheet_names
      @workbook.sheets.map { |sheet| normalize_name(sheet.name) }
    end

    def rows(sheet_name)
      headers = nil
      normalized_rows = []

      find_sheet(sheet_name).rows.each.with_index(1) do |raw_values, source_row_number|
        values = Array(raw_values)

        if headers.nil?
          next if blank_row?(values)

          headers = normalized_headers(values)
          next
        end

        next if blank_row?(values)

        normalized_rows << build_row(headers, values).merge("source_row_number" => source_row_number)
      end

      normalized_rows
    end

    private
      def build_row(headers, values)
        headers.each_with_object({}) do |(header, index), row|
          row[header] = values[index]
        end
      end

      def blank_row?(values)
        values.all?(&:blank?)
      end

      def find_sheet(sheet_name)
        normalized_sheet_name = normalize_name(sheet_name)

        @workbook.sheets.find { |sheet| normalize_name(sheet.name) == normalized_sheet_name } ||
          raise(KeyError, "Missing sheet #{sheet_name}")
      end

      def normalized_headers(values)
        values.each_with_index.filter_map do |value, index|
          normalized = normalize_name(value)
          next if normalized.blank?

          [ normalized, index ]
        end
      end

      def normalize_name(value)
        value.to_s.strip.downcase.tr(" -", "__").gsub(/_+/, "_").delete_prefix("_").delete_suffix("_")
      end
  end
end
