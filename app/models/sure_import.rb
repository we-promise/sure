class SureImport < Import
  PreflightError = Class.new(StandardError)

  DEFAULT_MAX_NDJSON_SIZE_MB = 10
  DEFAULT_MAX_ROW_COUNT = 100_000
  IMPORTABLE_NDJSON_TYPES = {
    "Account" => :accounts,
    "Balance" => :balances,
    "Category" => :categories,
    "Tag" => :tags,
    "Merchant" => :merchants,
    "RecurringTransaction" => :recurring_transactions,
    "Transaction" => :transactions,
    "Transfer" => :transfers,
    "RejectedTransfer" => :rejected_transfers,
    "Trade" => :trades,
    "Holding" => :holdings,
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
      positive_integer_env("SURE_IMPORT_MAX_ROWS", DEFAULT_MAX_ROW_COUNT)
    end

    def max_ndjson_size
      positive_integer_env("SURE_IMPORT_MAX_NDJSON_SIZE_MB", DEFAULT_MAX_NDJSON_SIZE_MB).megabytes
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

    private
      def positive_integer_env(name, default)
        value = ENV[name].to_i
        value.positive? ? value : default
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
    importer = Family::DataImporter.new(
      family,
      ndjson_blob_string,
      merge_existing_taxonomy: merge_existing_taxonomy?
    )
    result = importer.import!

    result[:accounts].each { |account| accounts << account }
    result[:entries].each { |entry| entries << entry }
  end

  def publish_later
    raise MaxRowCountExceededError if row_count_exceeded?

    validate_sure_preflight!
    raise "Import is not publishable" unless publishable?

    update! status: :importing

    ImportJob.perform_later(self)
  end

  def publish
    raise MaxRowCountExceededError if row_count_exceeded?

    validate_sure_preflight!

    import!

    family.sync_later

    update! status: :complete
  rescue => error
    update! status: :failed, error: error.message
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

  def merge_existing_taxonomy?
    ActiveModel::Type::Boolean.new.cast(import_options&.fetch("merge_existing_taxonomy", false))
  end

  def merge_existing_taxonomy=(value)
    self.import_options = (import_options || {}).merge(
      "merge_existing_taxonomy" => ActiveModel::Type::Boolean.new.cast(value)
    )
  end

  def sure_preflight
    SureImport::Preflight.new(
      family: family,
      content: ndjson_blob_string,
      merge_existing_taxonomy: merge_existing_taxonomy?
    ).call
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

    def validate_sure_preflight!
      result = sure_preflight
      return if result.valid?

      update! status: :failed, error: result.error_message
      raise PreflightError, result.error_message
    end
end
