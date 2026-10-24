require "test_helper"
require "zip"
require "cgi"

class Icost::FileParserTest < ActiveSupport::TestCase
  test "reads UTF8 CSV with BOM while retaining unknown headers precision and quoted newlines" do
    csv = "\uFEFF日期,金额,未知字段,未知字段\r\n2026/09/01 12:34:56,-12.3000,\"  合成\n备注  \",第二值\r\n"
    result = Icost::FileParser.call(bytes: csv.b, filename: "synthetic.csv")

    assert_equal [ "日期", "金额", "未知字段", "未知字段" ], result[:headers]
    assert_equal "CSV", result[:sheet_name]
    assert_equal 2, result[:rows].first[:row_number]
    assert_equal [ "2026/09/01 12:34:56", "-12.3000", "  合成\n备注  ", "第二值" ], result[:rows].first[:values]
  end

  test "does not evaluate formula-like CSV text" do
    result = Icost::FileParser.call(bytes: "日期,备注\n2026/09/01,=SUM(1:2)\n", filename: "synthetic.csv")
    assert_equal "=SUM(1:2)", result[:rows].first[:values][1]
  end

  test "retains sparse XLSX values rich strings booleans and numeric lexemes" do
    xml = <<~XML
      <worksheet xmlns="#{Icost::FileParser::SPREADSHEET_NS}"><sheetData>
        <row r="1"><c r="A1" t="inlineStr"><is><t>日期</t></is></c><c r="B1" t="s"><v>0</v></c><c r="D1" t="inlineStr"><is><t>未知</t></is></c></row>
        <row r="2"><c r="A2" t="inlineStr"><is><t>2026/09/01 01:02:03</t></is></c><c r="B2"><v>-12.3000</v></c><c r="D2" t="b"><v>1</v></c><c r="E2" t="s"><v>1</v></c></row>
        <row r="4"><c r="A4" t="n"><v>46266.5</v></c></row>
      </sheetData></worksheet>
    XML
    strings = <<~XML
      <sst xmlns="#{Icost::FileParser::SPREADSHEET_NS}"><si><t>金额</t></si><si><r><t xml:space="preserve">  合成</t></r><r><t>文字  </t></r></si></sst>
    XML
    result = parse_xlsx(xml, "xl/sharedStrings.xml" => strings)

    assert_equal [ "日期", "金额", "", "未知" ], result[:headers]
    assert_equal "合成账单", result[:sheet_name]
    assert_equal [ 2, 4 ], result[:rows].map { |row| row[:row_number] }
    assert_equal [ "2026/09/01 01:02:03", "-12.3000", nil, true, "  合成文字  " ], result[:rows].first[:values]
    assert_equal "46266.5", result[:rows].last[:values].first
  end

  test "never trusts cached formula results" do
    assert_error "formula_not_supported" do
      parse_xlsx(worksheet('<c r="A2"><f>SUM(1,2)</f><v>3</v></c>'))
    end
    assert_error "cell_error" do
      parse_xlsx(worksheet('<c r="A2" t="e"><v>#VALUE!</v></c>'))
    end
  end

  test "rejects XML document types external worksheet references and unsafe archive paths" do
    assert_error "xml_doctype_not_supported" do
      parse_xlsx('<!DOCTYPE worksheet [<!ENTITY secret SYSTEM "file:///private/synthetic">]>' + worksheet('<c r="A2" t="str"><v>&secret;</v></c>'))
    end
    assert_error "invalid_worksheet_relationship" do
      parse_xlsx(worksheet, "xl/_rels/workbook.xml.rels" => relationships(target: "https://example.invalid/sheet.xml", external: true))
    end
    assert_error "unsafe_archive_path" do
      parse_xlsx(worksheet, "../synthetic.xml" => "not read")
    end
  end

  test "does not silently ignore another worksheet" do
    workbook = "<workbook xmlns=\"#{Icost::FileParser::SPREADSHEET_NS}\" xmlns:r=\"#{Icost::FileParser::RELATIONSHIP_NS}\"><sheets><sheet name=\"A\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"B\" sheetId=\"2\" r:id=\"rId2\"/></sheets></workbook>"
    assert_error "multiple_worksheets" do
      parse_xlsx(worksheet, "xl/workbook.xml" => workbook)
    end
  end

  test "rejects invalid shared string indexes duplicate cell references and invalid coordinates" do
    assert_error "invalid_shared_string" do
      parse_xlsx(worksheet('<c r="A2" t="s"><v>99</v></c>'))
    end
    assert_error "duplicate_cell" do
      parse_xlsx(worksheet('<c r="A2"><v>1</v></c><c r="A2"><v>2</v></c>'))
    end
    assert_error "invalid_cell_reference" do
      parse_xlsx(worksheet('<c r="A3"><v>1</v></c>'))
    end
  end

  test "enforces file row column and cell bounds before returning values" do
    assert_error("file_too_large") { Icost::FileParser.call(bytes: "a" * (Icost::FileParser::MAX_FILE_BYTES + 1), filename: "synthetic.csv") }
    assert_error("invalid_csv") { Icost::FileParser.call(bytes: "日期\n#{'a' * (Icost::FileParser::MAX_CELL_BYTES + 1)}\n", filename: "synthetic.csv") }
    assert_error("cell_too_large") { parse_xlsx(worksheet("<c r=\"A2\" t=\"inlineStr\"><is><t>#{'a' * (Icost::FileParser::MAX_CELL_BYTES + 1)}</t></is></c>")) }
    assert_error("too_many_columns") { Icost::FileParser.call(bytes: "#{([ 'x' ] * (Icost::FileParser::MAX_COLUMNS + 1)).join(',')}\n1\n", filename: "synthetic.csv") }
    assert_error("too_many_rows") { parse_xlsx(worksheet.gsub('r="2"', 'r="10002"').gsub('r="A2"', 'r="A10002"')) }
  end

  test "rejects unsupported encodings empty files malformed CSV and unsupported formats without echoing content" do
    assert_error("invalid_encoding") { Icost::FileParser.call(bytes: "\xFF\xFE".b, filename: "synthetic.csv") }
    assert_error("empty_file") { Icost::FileParser.call(bytes: "", filename: "synthetic.csv") }
    assert_error("invalid_csv") { Icost::FileParser.call(bytes: "日期\n\"unclosed", filename: "synthetic.csv") }
    assert_error("unsupported_file_type") { Icost::FileParser.call(bytes: "synthetic", filename: "synthetic.xls") }
    assert_error("invalid_file") { Icost::FileParser.call(bytes: "日期,备注\n2026/09/01,synthetic\0\n", filename: "synthetic.csv") }
  end

  test "bounds archives and XML expansion before parsing worksheet contents" do
    entries = (1..Icost::FileParser::MAX_ZIP_ENTRIES).to_h { |number| [ "unused/#{number}.xml", "synthetic" ] }
    assert_error("archive_too_large") { parse_xlsx(worksheet, entries) }
    assert_error("archive_too_large") { parse_xlsx("a" * (Icost::FileParser::MAX_XML_BYTES + 1)) }
  end

  private

    def assert_error(code, &block)
      error = assert_raises(Icost::FileParser::Error, &block)
      assert_equal code, error.code
      assert_equal code, error.message
    end

    def worksheet(cells = '<c r="A2" t="inlineStr"><is><t>2026/09/01</t></is></c>')
      "<worksheet xmlns=\"#{Icost::FileParser::SPREADSHEET_NS}\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>日期</t></is></c></row><row r=\"2\">#{cells}</row></sheetData></worksheet>"
    end

    def relationships(target: "worksheets/sheet1.xml", external: false)
      "<Relationships xmlns=\"#{Icost::FileParser::PACKAGE_NS}\"><Relationship Id=\"rId1\" Type=\"#{Icost::FileParser::RELATIONSHIP_NS}/worksheet\" Target=\"#{CGI.escapeHTML(target)}\"#{external ? ' TargetMode="External"' : ''}/></Relationships>"
    end

    def parse_xlsx(sheet, overrides = {})
      files = {
        "xl/workbook.xml" => "<workbook xmlns=\"#{Icost::FileParser::SPREADSHEET_NS}\" xmlns:r=\"#{Icost::FileParser::RELATIONSHIP_NS}\"><sheets><sheet name=\"合成账单\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>",
        "xl/_rels/workbook.xml.rels" => relationships,
        "xl/worksheets/sheet1.xml" => sheet
      }.merge(overrides)
      buffer = Zip::OutputStream.write_buffer do |zip|
        files.each do |name, content|
          zip.put_next_entry(name)
          zip.write(content)
        end
      end
      Icost::FileParser.call(bytes: buffer.string, filename: "synthetic.xlsx")
    end
end
