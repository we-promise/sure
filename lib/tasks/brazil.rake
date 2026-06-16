require "open-uri"
require "stringio"

namespace :brazil do
  desc "Import Brazilian STR participant banks from the Banco Central CSV"
  task import_banks: :environment do
    source = ENV.fetch("SOURCE", Brazil::BankCatalogImporter::SOURCE_URL)
    text =
      if source.match?(/\Ahttps?:\/\//)
        URI.open(source, &:read)
      elsif File.exist?(source)
        File.read(source)
      else
        raise "Source not found: #{source}"
      end
    text = text.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace).delete_prefix("\uFEFF")

    imported_count = Brazil::BankCatalogImporter.new(text: text, source: source).call
    puts "Imported #{imported_count} Brazilian bank catalog rows"
  end
end
