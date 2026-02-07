class BulkImport < Import
  ALLOWED_NDJSON_MIME_TYPES = %w[application/x-ndjson application/json text/plain].freeze

  def import!
    importer = Family::DataImporter.new(family, raw_file_str)
    result = importer.import!

    # Track created accounts and entries for potential revert
    result[:accounts].each { |account| accounts << account }
    result[:entries].each { |entry| entries << entry }
  end

  def column_keys
    [] # NDJSON import doesn't use column mapping
  end

  def required_column_keys
    [] # NDJSON import doesn't use column mapping
  end

  def mapping_steps
    [] # NDJSON import doesn't use mapping steps
  end

  def dry_run
    return {} unless raw_file_str.present?

    counts = parse_ndjson_counts
    {
      accounts: counts["Account"] || 0,
      categories: counts["Category"] || 0,
      tags: counts["Tag"] || 0,
      merchants: counts["Merchant"] || 0,
      transactions: counts["Transaction"] || 0,
      trades: counts["Trade"] || 0,
      valuations: counts["Valuation"] || 0,
      budgets: counts["Budget"] || 0,
      budget_categories: counts["BudgetCategory"] || 0,
      rules: counts["Rule"] || 0
    }
  end

  def csv_template
    nil # NDJSON import doesn't have a CSV template
  end

  def generate_rows_from_csv
    # NDJSON import doesn't use CSV rows, but we need to set rows_count
    counts = parse_ndjson_counts
    total = counts.values.sum
    update_column(:rows_count, total)
  end

  # Override to validate NDJSON format
  def uploaded?
    raw_file_str.present? && valid_ndjson?
  end

  # NDJSON imports are always configured once uploaded
  def configured?
    uploaded?
  end

  # NDJSON imports are always clean (structured data)
  def cleaned?
    configured?
  end

  # NDJSON imports are publishable once uploaded and valid
  def publishable?
    cleaned?
  end

  def max_row_count
    100_000 # Higher limit for bulk imports
  end

  private

    def parse_ndjson_counts
      return {} unless raw_file_str.present?

      counts = Hash.new(0)
      raw_file_str.each_line do |line|
        next if line.strip.empty?
        begin
          record = JSON.parse(line)
          counts[record["type"]] += 1 if record["type"]
        rescue JSON::ParserError
          # Skip invalid lines
        end
      end
      counts
    end

    def valid_ndjson?
      return false unless raw_file_str.present?

      # Check at least first line is valid NDJSON
      first_line = raw_file_str.lines.first&.strip
      return false if first_line.blank?

      begin
        record = JSON.parse(first_line)
        record.key?("type") && record.key?("data")
      rescue JSON::ParserError
        false
      end
    end
end
