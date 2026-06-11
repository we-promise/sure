require "test_helper"

module TaxWorkbook
  class SheetReaderTest < ActiveSupport::TestCase
    test "reads normalized rows from generated template" do
      with_template_file do |tempfile|
        reader = SheetReader.new(tempfile.path)

        assert_equal TaxWorkbook::Template::SHEET_NAMES, reader.sheet_names
        assert_equal TaxWorkbook::Template.headers_for("meta"), reader.headers("meta")

        meta_row = reader.rows("Meta").first
        assert_equal "Risingstone infra pvt ltd", meta_row.fetch("entity_name")
        assert_equal 2, meta_row.fetch("source_row_number")

        outward_row = reader.rows("gst outward lines").first
        assert_equal "INV-001", outward_row.fetch("invoice_no")
        assert_equal false, outward_row.fetch("is_reverse_charge")
      end
    end

    test "reads headers from sheets without data rows" do
      with_empty_data_workbook do |tempfile|
        reader = SheetReader.new(tempfile.path)

        assert_equal [ "invoice_no", "taxable_value" ], reader.headers("gst-outward-lines")
        assert_empty reader.rows("gst-outward-lines")
      end
    end

    test "normalizes headers and skips blank rows" do
      with_blank_row_workbook do |tempfile|
        reader = SheetReader.new(tempfile.path)
        rows = reader.rows("gst-outward-lines")

        assert_equal 1, rows.length
        assert_equal [ "invoice_no", "taxable_value", "source_row_number" ], rows.first.keys
        assert_equal "INV-002", rows.first.fetch("invoice_no")
        assert_equal 4, rows.first.fetch("source_row_number")
      end
    end

    private
      def with_template_file
        xlsx = TaxWorkbook::TemplateGenerator.new.call
        tempfile = Tempfile.new([ "tax-template", ".xlsx" ])
        tempfile.binmode
        tempfile.write(xlsx)
        tempfile.rewind

        yield tempfile
      ensure
        tempfile&.close!
      end

      def with_blank_row_workbook
        package = Axlsx::Package.new(author: "Sure")
        package.workbook.add_worksheet(name: "gst outward lines") do |sheet|
          sheet.add_row [ "Invoice No", "Taxable Value" ]
          sheet.add_row []
          sheet.add_row [ nil, " " ]
          sheet.add_row [ "INV-002", 2500 ]
        end

        tempfile = Tempfile.new([ "tax-template-with-blanks", ".xlsx" ])
        tempfile.binmode
        tempfile.write(package.to_stream.read)
        tempfile.rewind

        yield tempfile
      ensure
        tempfile&.close!
      end

      def with_empty_data_workbook
        package = Axlsx::Package.new(author: "Sure")
        package.workbook.add_worksheet(name: "gst outward lines") do |sheet|
          sheet.add_row [ "Invoice No", "Taxable Value" ]
        end

        tempfile = Tempfile.new([ "tax-template-empty-data", ".xlsx" ])
        tempfile.binmode
        tempfile.write(package.to_stream.read)
        tempfile.rewind

        yield tempfile
      ensure
        tempfile&.close!
      end
  end
end
