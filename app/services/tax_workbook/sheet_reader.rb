module TaxWorkbook
  class SheetReader
    def initialize(path)
      @workbook = SimpleXlsxReader.open(path)
    end

    def sheet_names
      @workbook.sheets.map { |sheet| normalize_name(sheet.name) }
    end

    def headers(sheet_name)
      header_row(sheet_name).fetch(:columns).map(&:first)
    end

    def rows(sheet_name)
      headers = header_row(sheet_name)
      normalized_rows = []

      find_sheet(sheet_name).rows.each.with_index(1) do |raw_values, source_row_number|
        values = Array(raw_values)

        next if source_row_number <= headers.fetch(:source_row_number)

        next if blank_row?(values)

        normalized_rows << build_row(headers.fetch(:columns), values).merge("source_row_number" => source_row_number)
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
        values.all? { |value| value.nil? || value.to_s.strip.empty? }
      end

      def find_sheet(sheet_name)
        normalized_sheet_name = normalize_name(sheet_name)

        @workbook.sheets.find { |sheet| normalize_name(sheet.name) == normalized_sheet_name } ||
          raise(KeyError, "Missing sheet #{sheet_name}")
      end

      def header_row(sheet_name)
        find_sheet(sheet_name).rows.each.with_index(1) do |values, source_row_number|
          next if blank_row?(Array(values))

          return { columns: normalized_headers(Array(values)), source_row_number: source_row_number }
        end

        { columns: [], source_row_number: 0 }
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
