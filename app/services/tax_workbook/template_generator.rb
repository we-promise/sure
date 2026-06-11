require "caxlsx"

module TaxWorkbook
  class TemplateGenerator
    HEADER_FILL_COLOR = "FFE5E7EB"

    def call
      package = Axlsx::Package.new(author: "Sure")
      workbook = package.workbook
      header_style = workbook.styles.add_style(b: true, bg_color: HEADER_FILL_COLOR)

      Template::SHEET_NAMES.each do |sheet_name|
        workbook.add_worksheet(name: sheet_name) do |sheet|
          headers = Template.headers_for(sheet_name)

          sheet.add_row headers, style: Array.new(headers.length, header_style)
          sheet.add_row Template.sample_for(sheet_name)
        end
      end

      validation_errors = package.validate
      if validation_errors.any?
        raise ArgumentError, "Invalid tax workbook template: #{validation_errors.map(&:message).join(', ')}"
      end

      package.to_stream.read
    end
  end
end
