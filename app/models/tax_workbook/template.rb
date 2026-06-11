module TaxWorkbook
  module Template
    VERSION = "1"

    SHEETS = {
      "meta" => {
        headers: %w[entity_name gstin tan fy tax_period_month tax_period_quarter return_type source_system source_file_name].freeze,
        sample: [ "Risingstone infra pvt ltd", "27ABCDE1234F1Z5", "MUMR12345A", "2026-27", "2026-04", "Q1", "GST_TDS", "Google Sheets", "india_tax_april_2026.xlsx" ].freeze
      },
      "gst_outward_lines" => {
        headers: %w[gstr1_table_code invoice_no invoice_date recipient_gstin_or_uin place_of_supply_state hsn_code rate_pct taxable_value igst cgst sgst_ugst cess is_reverse_charge is_export is_ecommerce_tcs is_credit_note is_debit_note].freeze,
        sample: [ "4A", "INV-001", "2026-04-10", "27ABCDE1234F1Z5", "Maharashtra", "998314", 18, 10_000, 0, 900, 900, 0, false, false, false, false, false ].freeze
      },
      "gst_3b_summary" => {
        headers: %w[section_code taxable_value igst cgst sgst_ugst cess interest late_fee].freeze,
        sample: [ "3.1(a)", 10_000, 0, 900, 900, 0, 0, 0 ].freeze
      },
      "gst_hsn_summary" => {
        headers: %w[hsn_code description uqc quantity taxable_value igst cgst sgst_ugst cess bucket].freeze,
        sample: [ "998314", "IT consulting services", "NA", 1, 10_000, 0, 900, 900, 0, "B2B" ].freeze
      },
      "tds_deductions" => {
        headers: %w[deductor_tan deductee_pan_or_aadhaar deductee_name section_code booking_date payment_date amount_paid tds_rate_pct tds_amount surcharge cess challan_ref resident_status].freeze,
        sample: [ "MUMR12345A", "ABCDE1234F", "Vendor Pvt Ltd", "194J", "2026-04-15", "2026-04-20", 50_000, 10, 5_000, 0, 0, "CH-APR-001", "resident" ].freeze
      },
      "tds_challans" => {
        headers: %w[challan_ref mode_of_deposit bsr_code_or_receipt_no challan_serial_no_or_ddo_serial_no deposit_date minor_head tax interest fee penalty others total_amount].freeze,
        sample: [ "CH-APR-001", "challan", "1234567", "00001", "2026-05-07", "200", 5_000, 0, 0, 0, 0, 5_000 ].freeze
      }
    }.freeze

    SHEET_NAMES = SHEETS.keys.freeze

    def self.headers_for(sheet_name)
      SHEETS.fetch(sheet_name).fetch(:headers)
    end

    def self.sample_for(sheet_name)
      SHEETS.fetch(sheet_name).fetch(:sample)
    end
  end
end
