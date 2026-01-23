#!/usr/bin/env ruby
# ===========================================================================
# Transform Old Export to Import-Compatible Format
# ===========================================================================
#
# This script transforms Sure export files from the old format to the new
# import-compatible format. Uses Ruby's CSV library for proper handling of
# quoted fields, embedded commas, etc.
#
# Usage:
#   ruby scripts/transform-export.rb <export_directory>
#
# Example:
#   ruby scripts/transform-export.rb ./data/backups/sure_export_20260119_181110
#
# Or run inside Docker:
#   docker exec sure-web-persistent ruby scripts/transform-export.rb /path/to/export
#
# ===========================================================================

require "csv"
require "fileutils"

class ExportTransformer
  def initialize(source_dir)
    @source_dir = source_dir
    @output_dir = "#{source_dir}_importable"
  end

  def transform!
    validate_source!
    create_output_dir!

    puts "\n\e[34m[INFO]\e[0m Transforming export from: #{@source_dir}"
    puts "\e[34m[INFO]\e[0m Output directory: #{@output_dir}\n\n"

    transform_accounts
    transform_transactions
    transform_trades
    copy_categories
    copy_rules
    copy_ndjson

    print_summary
  end

  private

  def validate_source!
    unless File.directory?(@source_dir)
      puts "\e[31m[ERROR]\e[0m Directory not found: #{@source_dir}"
      exit 1
    end
  end

  def create_output_dir!
    FileUtils.mkdir_p(@output_dir)
  end

  def transform_accounts
    source_file = File.join(@source_dir, "accounts.csv")
    return warn_missing("accounts.csv") unless File.exist?(source_file)

    puts "\e[34m[INFO]\e[0m Transforming accounts.csv..."

    rows = CSV.read(source_file, headers: true)
    count = 0

    CSV.open(File.join(@output_dir, "accounts.csv"), "w") do |csv|
      # New header matching AccountImport csv_template
      csv << ["account_type", "name", "balance", "currency", "balance_date"]

      rows.each do |row|
        # Extract date from ISO timestamp (2026-01-15T21:48:57-06:00 -> 2026-01-15)
        created_at = row["created_at"].to_s
        balance_date = created_at.split("T").first

        csv << [
          row["type"],           # account_type
          row["name"],           # name
          row["balance"],        # balance
          row["currency"],       # currency
          balance_date           # balance_date
        ]
        count += 1
      end
    end

    puts "\e[32m[SUCCESS]\e[0m accounts.csv transformed (#{count} rows)"
  end

  def transform_transactions
    source_file = File.join(@source_dir, "transactions.csv")
    return warn_missing("transactions.csv") unless File.exist?(source_file)

    puts "\e[34m[INFO]\e[0m Transforming transactions.csv..."

    rows = CSV.read(source_file, headers: true)
    count = 0

    CSV.open(File.join(@output_dir, "transactions.csv"), "w") do |csv|
      # New header matching TransactionImport csv_template
      csv << ["date", "amount", "name", "currency", "category", "tags", "account", "notes"]

      rows.each do |row|
        # Convert tags from comma-separated to pipe-separated
        tags = row["tags"].to_s.gsub(",", "|")

        csv << [
          row["date"],           # date
          row["amount"],         # amount
          row["name"],           # name
          row["currency"],       # currency
          row["category"],       # category
          tags,                  # tags (pipe-separated)
          row["account_name"],   # account (was account_name)
          row["notes"]           # notes
        ]
        count += 1
      end
    end

    puts "\e[32m[SUCCESS]\e[0m transactions.csv transformed (#{count} rows)"
  end

  def transform_trades
    source_file = File.join(@source_dir, "trades.csv")
    return warn_missing("trades.csv") unless File.exist?(source_file)

    puts "\e[34m[INFO]\e[0m Transforming trades.csv..."

    rows = CSV.read(source_file, headers: true)
    count = 0

    CSV.open(File.join(@output_dir, "trades.csv"), "w") do |csv|
      # New header matching TradeImport csv_template
      csv << ["date", "ticker", "exchange_operating_mic", "currency", "qty", "price", "account", "name"]

      rows.each do |row|
        csv << [
          row["date"],           # date
          row["ticker"],         # ticker
          "",                    # exchange_operating_mic (not in old format)
          row["currency"],       # currency
          row["quantity"],       # qty (was quantity)
          row["price"],          # price
          row["account_name"],   # account (was account_name)
          ""                     # name (not in old format)
        ]
        count += 1
      end
    end

    puts "\e[32m[SUCCESS]\e[0m trades.csv transformed (#{count} rows)"
  end

  def copy_categories
    source_file = File.join(@source_dir, "categories.csv")
    return warn_missing("categories.csv") unless File.exist?(source_file)

    puts "\e[34m[INFO]\e[0m Copying categories.csv (format already compatible)..."

    FileUtils.cp(source_file, File.join(@output_dir, "categories.csv"))
    count = CSV.read(source_file, headers: true).count

    puts "\e[32m[SUCCESS]\e[0m categories.csv copied (#{count} rows)"
  end

  def copy_rules
    source_file = File.join(@source_dir, "rules.csv")
    return warn_missing("rules.csv") unless File.exist?(source_file)

    puts "\e[34m[INFO]\e[0m Copying rules.csv (format already compatible)..."

    FileUtils.cp(source_file, File.join(@output_dir, "rules.csv"))
    count = CSV.read(source_file, headers: true).count

    puts "\e[32m[SUCCESS]\e[0m rules.csv copied (#{count} rows)"
  end

  def copy_ndjson
    source_file = File.join(@source_dir, "all.ndjson")
    return unless File.exist?(source_file)

    puts "\e[34m[INFO]\e[0m Copying all.ndjson (preserved for future use)..."

    FileUtils.cp(source_file, File.join(@output_dir, "all.ndjson"))

    puts "\e[32m[SUCCESS]\e[0m all.ndjson copied"
  end

  def warn_missing(filename)
    puts "\e[33m[WARN]\e[0m #{filename} not found, skipping"
  end

  def print_summary
    puts "\n\e[32m[SUCCESS]\e[0m Transformation complete!"
    puts "\nTransformed files are in: #{@output_dir}"
    puts "\nImport order (recommended):"
    puts "  1. categories.csv   - Import as Category Import"
    puts "  2. accounts.csv     - Import as Account Import"
    puts "  3. transactions.csv - Import as Transaction Import"
    puts "  4. trades.csv       - Import as Trade Import (if you have trades)"
    puts "  5. rules.csv        - Import as Rule Import"
    puts "\nNote: When importing, the columns should auto-map correctly."
    puts "If not, manually map columns in the configuration step."
  end
end

# Main
if ARGV.empty?
  puts "\e[31m[ERROR]\e[0m Usage: ruby #{$0} <export_directory>"
  puts "\nExample:"
  puts "  ruby #{$0} ./data/backups/sure_export_20260119_181110"
  exit 1
end

ExportTransformer.new(ARGV[0]).transform!
