class SureImport < Import
  MAX_NDJSON_SIZE = 10.megabytes
  IMPORTABLE_NDJSON_TYPES = {
    "Account" => :accounts,
    "Category" => :categories,
    "Tag" => :tags,
    "Merchant" => :merchants,
    "Transaction" => :transactions,
    "Trade" => :trades,
    "Valuation" => :valuations,
    "Budget" => :budgets,
    "BudgetCategory" => :budget_categories,
    "Rule" => :rules
  }.freeze
  ALLOWED_NDJSON_CONTENT_TYPES = %w[
    application/x-ndjson
    application/ndjson
    application/json
    application/octet-stream
    text/plain
  ].freeze

  has_one_attached :ndjson_file, dependent: :purge_later

  class << self
    def max_row_count
      100_000
    end

    def max_ndjson_size
      MAX_NDJSON_SIZE
    end

    # Counts JSON lines by top-level "type" (used for dry-run summaries and row limits).
    def ndjson_line_type_counts(content)
      return {} unless content.present?

      counts = Hash.new(0)
      content.each_line do |line|
        next if line.strip.empty?

        begin
          record = JSON.parse(line)
          counts[record["type"]] += 1 if record.is_a?(Hash) && record["type"] && record.key?("data")
        rescue JSON::ParserError
          # Skip invalid lines
        end
      end
      counts
    end

    def dry_run_totals_from_ndjson(content)
      dry_run_totals_from_line_type_counts(ndjson_line_type_counts(content))
    end

    def dry_run_totals_from_line_type_counts(counts)
      IMPORTABLE_NDJSON_TYPES.to_h do |record_type, entity_key|
        [ entity_key, counts[record_type] || 0 ]
      end
    end

    def importable_ndjson_types
      IMPORTABLE_NDJSON_TYPES.keys
    end

    def valid_ndjson_first_line?(str)
      return false if str.blank?

      first_line = str.lines.first&.strip
      return false if first_line.blank?

      begin
        record = JSON.parse(first_line)
        record.is_a?(Hash) && record.key?("type") && record.key?("data")
      rescue JSON::ParserError
        false
      end
    end
  end

  def requires_csv_workflow?
    false
  end

  def column_keys
    []
  end

  def required_column_keys
    []
  end

  def mapping_steps
    []
  end

  def csv_template
    nil
  end

  def dry_run
    return {} unless uploaded?

    self.class.dry_run_totals_from_ndjson(ndjson_blob_string)
  end

  def import!
    importer = Family::DataImporter.new(family, ndjson_blob_string)
    result = importer.import!

    result[:accounts].each { |account| accounts << account }
    result[:entries].each { |entry| entries << entry }
  end

  def uploaded?
    return false unless ndjson_file.attached?

    self.class.valid_ndjson_first_line?(ndjson_blob_string)
  end

  def configured?
    uploaded?
  end

  def cleaned?
    configured?
  end

  def publishable?
    cleaned? && dry_run.values.sum.positive?
  end

  def cleaned_from_validation_stats?(invalid_rows_count:)
    configured? && invalid_rows_count.zero?
  end

  def publishable_from_validation_stats?(invalid_rows_count:)
    cleaned_from_validation_stats?(invalid_rows_count: invalid_rows_count) && dry_run.values.sum.positive?
  end

  def max_row_count
    self.class.max_row_count
  end

  # Row total for max-row enforcement (counts every parsed line with a "type", including unsupported types).
  def sync_ndjson_rows_count!
    return unless ndjson_file.attached?

    total = self.class.ndjson_line_type_counts(ndjson_blob_string).values.sum
    update_column(:rows_count, total)
  end

  private

    def ndjson_blob_string
      blob_id = ndjson_file.blob&.id

      return @ndjson_blob_string if defined?(@ndjson_blob_string) && @ndjson_blob_id == blob_id

      @ndjson_blob_id = blob_id
      @ndjson_blob_string = ndjson_file.download.force_encoding(Encoding::UTF_8)
    end
end
