# Minimal, dependency-light reader for .xlsx workbooks.
#
# An .xlsx file is a zip of XML parts. We only depend on rubyzip + nokogiri
# (both already in the Gemfile) rather than pulling in `roo`, per the project's
# "minimize dependencies" convention.
#
# Responsibilities (intentionally low-level):
#   - enumerate the sheets in workbook order, resolving each sheet to its
#     worksheet XML part via the workbook relationships (NOT by sheetN order,
#     which does not match the tab order in real exports)
#   - expose the shared-strings table
#   - return a sheet's cells as a 1-based row/column matrix of raw values
#
# Date/number interpretation is deliberately left to the caller: callers know
# the role of each column (e.g. "this column is a date") and can convert Excel
# serial numbers via .excel_serial_to_date, which is more robust than guessing
# from cell styles.
class Import::XlsxWorkbook
  Sheet = Struct.new(:name, :state, :rid, :path, keyword_init: true) do
    def hidden?
      state.present? && state != "visible"
    end
  end

  Error = Class.new(StandardError)

  NS = {
    "ss"  => "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "r"   => "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    "rel" => "http://schemas.openxmlformats.org/package/2006/relationships"
  }.freeze

  # Excel's day 0 is 1899-12-31, but the 1900 leap-year bug means treating
  # 1899-12-30 as the epoch yields correct dates for all serials >= 60.
  EXCEL_EPOCH = Date.new(1899, 12, 30)

  class << self
    def open(content_or_io)
      new(content_or_io)
    end

    # Converts an Excel date serial (e.g. 45657) to a Ruby Date (2024-12-31).
    def excel_serial_to_date(serial)
      return nil if serial.nil?

      number = serial.is_a?(String) ? Float(serial) : serial.to_f
      EXCEL_EPOCH + number.floor
    rescue ArgumentError, TypeError
      nil
    end

    def column_letter_to_index(letters)
      letters.to_s.upcase.each_char.reduce(0) do |acc, ch|
        acc * 26 + (ch.ord - "A".ord + 1)
      end
    end
  end

  def initialize(content_or_io)
    @zip = open_zip(content_or_io)
  end

  # Sheets in workbook (tab) order.
  def sheets
    @sheets ||= begin
      doc = parse_xml(read_entry("xl/workbook.xml"))
      rels = workbook_relationships

      doc.xpath("//ss:sheets/ss:sheet", NS).map do |node|
        rid = node["r:id"] || node.attribute_with_ns("id", NS["r"])&.value
        target = rels[rid]

        Sheet.new(
          name: node["name"],
          state: node["state"] || "visible",
          rid: rid,
          path: target && normalize_part_path(target)
        )
      end
    end
  end

  def sheet_names
    sheets.map(&:name)
  end

  def visible_sheets
    sheets.reject(&:hidden?)
  end

  # Visible sheets that could hold an account's transactions: excludes the
  # summary tab. Used by the heuristic detector when there's no manifest.
  def visible_account_candidate_sheets
    visible_sheets.reject { |s| s.name == Import::AccountSheetDetector::SUMMARY_SHEET_NAME }
  end

  def sheet(name)
    sheets.find { |s| s.name == name }
  end

  # Returns the sheet's cells as a Hash keyed by 1-based row number, each value
  # a Hash keyed by 1-based column number => raw value (String for shared/inline
  # strings, BigDecimal-friendly String for numbers, or nil for blanks).
  #
  # max_rows lets callers cap reads on huge sheets (e.g. previews).
  def cell_matrix(name, max_rows: nil)
    sheet = sheet(name)
    raise Error, "Unknown sheet: #{name.inspect}" unless sheet
    raise Error, "Sheet #{name.inspect} has no worksheet part" unless sheet.path

    doc = parse_xml(read_entry(sheet.path))
    matrix = {}

    doc.xpath("//ss:sheetData/ss:row", NS).each do |row_node|
      row_index = row_node["r"].to_i
      break if max_rows && row_index > max_rows

      row_node.xpath("ss:c", NS).each do |cell_node|
        ref = cell_node["r"]
        col_index = self.class.column_letter_to_index(ref.to_s.gsub(/\d+/, ""))
        value = cell_value(cell_node)
        next if value.nil?

        (matrix[row_index] ||= {})[col_index] = value
      end
    end

    matrix
  end

  # Convenience: a sheet as an array of arrays (1-based logic flattened to
  # 0-based arrays), nil-filled for gaps. Mostly for tests/inspection.
  def rows(name, max_rows: nil)
    matrix = cell_matrix(name, max_rows: max_rows)
    return [] if matrix.empty?

    last_row = matrix.keys.max
    (1..last_row).map do |r|
      cols = matrix[r] || {}
      last_col = cols.keys.max || 0
      (1..last_col).map { |c| cols[c] }
    end
  end

  def shared_strings
    @shared_strings ||= load_shared_strings
  end

  private
    def load_shared_strings
      return [] unless find_entry("xl/sharedStrings.xml")

      doc = parse_xml(read_entry("xl/sharedStrings.xml"))
      doc.xpath("//ss:si", NS).map do |si|
        # Plain <t> or rich text runs <r><t>; concatenate all text nodes.
        si.xpath(".//ss:t", NS).map(&:text).join
      end
    end

    def cell_value(cell_node)
      type = cell_node["t"]

      case type
      when "s" # shared string
        v = cell_node.at_xpath("ss:v", NS)&.text
        return nil if v.nil?
        shared_strings[v.to_i]
      when "inlineStr"
        cell_node.at_xpath(".//ss:t", NS)&.text
      when "str" # formula string result
        cell_node.at_xpath("ss:v", NS)&.text
      else # numeric (possibly a date serial) or formula with cached numeric value
        cell_node.at_xpath("ss:v", NS)&.text
      end
    end

    def workbook_relationships
      doc = parse_xml(read_entry("xl/_rels/workbook.xml.rels"))
      doc.xpath("//rel:Relationship", NS).each_with_object({}) do |node, acc|
        acc[node["Id"]] = node["Target"]
      end
    end

    def normalize_part_path(target)
      # Relationship targets are either absolute from the package root
      # ("/xl/worksheets/sheet1.xml", as written by openpyxl) or relative to the
      # workbook part's folder ("worksheets/sheet1.xml", as written by Excel).
      # Zip entries are stored without a leading slash.
      if target.start_with?("/")
        target.sub(%r{\A/}, "")
      else
        "xl/#{target}"
      end.gsub(%r{/\./}, "/")
    end

    def open_zip(content_or_io)
      if content_or_io.is_a?(String)
        # Raw .xlsx bytes start with the zip magic "PK"; anything else is a path.
        if content_or_io.byteslice(0, 2) == "PK".b
          Zip::File.open_buffer(StringIO.new(content_or_io.b))
        else
          Zip::File.open(content_or_io)
        end
      elsif content_or_io.respond_to?(:to_path)
        Zip::File.open(content_or_io.to_path)
      else
        Zip::File.open_buffer(content_or_io)
      end
    rescue Zip::Error => e
      raise Error, "Not a valid .xlsx file: #{e.message}"
    end

    def find_entry(path)
      @zip.find_entry(path)
    end

    def read_entry(path)
      entry = find_entry(path)
      raise Error, "Missing part: #{path}" unless entry
      entry.get_input_stream.read
    end

    def parse_xml(string)
      Nokogiri::XML(string) { |config| config.strict.nonet }
    rescue Nokogiri::XML::SyntaxError => e
      raise Error, "Malformed XML in workbook: #{e.message}"
    end
end
