require "caxlsx"

module TaxWorkbookMockData
  REALISTIC_TAX_WORKBOOK_ROWS = {
    "meta" => [
      [
        "Risingstone Infra Pvt Ltd",
        "27ABCDE1234F1Z5",
        "MUMR12345A",
        "2026-27",
        "2026-04",
        "Q1",
        "GST_TDS",
        "Zoho Books",
        "risingstone_april_2026_gst_tds.xlsx"
      ]
    ],
    "gst_outward_lines" => [
      [ "4A", "RS-APR-001", "2026-04-05", "29ABCDE1234F1Z7", "Karnataka", "998314", 18, 120_000, 21_600, 0, 0, 0, false, false, false, false, false ],
      [ "4A", "RS-APR-002", "2026-04-12", "27FGHIJ5678K1Z9", "Maharashtra", "998315", 18, 50_000, 0, 4_500, 4_500, 0, false, false, false, false, false ],
      [ "9B", "CN-APR-001", "2026-04-20", "27FGHIJ5678K1Z9", "Maharashtra", "998315", 18, -10_000, 0, -900, -900, 0, false, false, false, true, false ]
    ],
    "gst_3b_summary" => [
      [ "3.1(a)", 160_000, 21_600, 3_600, 3_600, 0, 0, 0 ],
      [ "6.1", 0, 0, 0, 0, 0, 0, 50 ]
    ],
    "gst_hsn_summary" => [
      [ "998314", "Software implementation services", "NA", 1, 120_000, 21_600, 0, 0, 0, "B2B" ],
      [ "998315", "Monthly support services", "NA", 1, 40_000, 0, 3_600, 3_600, 0, "B2B" ]
    ],
    "tds_deductions" => [
      [ "MUMR12345A", "ABCDE1234F", "Vendor Pvt Ltd", "194J", "2026-04-08", "2026-04-10", 50_000, 10, 5_000, 0, 0, "CH-APR-001", "resident" ],
      [ "MUMR12345A", "FGHIJ5678K", "Contractor LLP", "194C", "2026-04-14", "2026-04-18", 100_000, 2, 2_000, 0, 0, "CH-APR-001", "resident" ],
      [ "MUMR12345A", "123456789012", "Freelance Designer", "194J", "2026-04-22", "2026-04-25", 15_000, 10, 1_500, 0, 0, "CH-APR-002", "resident" ]
    ],
    "tds_challans" => [
      [ "CH-APR-001", "challan", "1234567", "00042", "2026-05-07", "200", 7_000, 0, 0, 0, 0, 7_000 ],
      [ "CH-APR-002", "challan", "1234567", "00043", "2026-05-07", "200", 1_500, 0, 0, 0, 0, 1_500 ]
    ]
  }.freeze

  def realistic_tax_workbook_content
    package = Axlsx::Package.new(author: "Sure")

    TaxWorkbook::Template::SHEET_NAMES.each do |sheet_name|
      package.workbook.add_worksheet(name: sheet_name) do |sheet|
        sheet.add_row TaxWorkbook::Template.headers_for(sheet_name)
        REALISTIC_TAX_WORKBOOK_ROWS.fetch(sheet_name).each do |row|
          sheet.add_row row, types: Array.new(row.length, :string)
        end
      end
    end

    package.to_stream.read
  end
end
