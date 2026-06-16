require "open-uri"

if Brazil::Bank.none?
  begin
    text = URI.open(Brazil::BankCatalogImporter::SOURCE_URL, &:read)
    text = text.force_encoding("UTF-8")
               .encode("UTF-8", invalid: :replace, undef: :replace)
               .delete_prefix("﻿")
    count = Brazil::BankCatalogImporter.new(text: text).call
    puts "  Seeded #{count} Brazilian banks from Banco Central"
  rescue => e
    puts "  Skipped Brazil bank catalog (#{e.class}: #{e.message})"
  end
else
  puts "  Brazilian banks already seeded (#{Brazil::Bank.count} records)"
end