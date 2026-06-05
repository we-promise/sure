class SureImport < Import
  NotPublishableError = Class.new(StandardError)
  PreflightError = Class.new(StandardError)

  DEFAULT_MAX_NDJSON_SIZE_MB = 10
  DEFAULT_MAX_ROW_COUNT = 100_000
  MAX_NDJSON_SIZE = DEFAULT_MAX_NDJSON_SIZE_MB.megabytes
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
  VERIFICATION_STATUSES = %w[not_verified matched mismatch failed reverted].freeze
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

    def expected_record_counts_from_ndjson(content)
      expected_record_counts_from_line_type_counts(ndjson_line_type_counts(content))
    end

    def expected_record_counts_from_line_type_counts(counts)
      dry_run_totals_from_line_type_counts(counts).transform_keys(&:to_s)
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

  def import!(import_session: nil)
    sync_ndjson_counts!
    before_counts = readback_count_snapshot
    importer = Family::DataImporter.new(family, ndjson_blob_string, import_session: import_session, import: self)
    result = importer.import!

    Import.transaction do
      result[:accounts].each { |account| account.save! if account.new_record? }
      result[:entries].each { |entry| entry.save! if entry.new_record? }

      account_ids = result[:accounts].filter_map(&:id)
      entry_ids = result[:entries].filter_map(&:id)
      existing_account_ids = accounts.where(id: account_ids).pluck(:id)
      existing_entry_ids = entries.where(id: entry_ids).pluck(:id)

      accounts.concat(result[:accounts].reject { |account| existing_account_ids.include?(account.id) })
      entries.concat(result[:entries].reject { |entry| existing_entry_ids.include?(entry.id) })
      update!(summary: result[:summary]) if has_attribute?(:summary)
    end

    record_readback_verification!(before_counts:)
    result
  rescue => error
    record_failed_readback_verification!(before_counts:, error:)
    raise
  end

  def publish_later
    raise MaxRowCountExceededError if row_count_exceeded?

    validate_sure_preflight!
    raise NotPublishableError, "Import was uploaded but has no publishable records." unless publishable?

    previous_status = status
    update! status: :importing

    begin
      ImportJob.perform_later(self)
    rescue StandardError
      update! status: previous_status
      raise
    end
  end

  def publish
    raise MaxRowCountExceededError if row_count_exceeded?

    validate_sure_preflight!

    import!

    family.sync_later

    update! status: :complete
  rescue StandardError => error
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

  def sure_preflight
    SureImport::Preflight.new(
      family: family,
      content: ndjson_blob_string
    ).call
  end

  # Row total for max-row enforcement (counts every parsed line with a "type", including unsupported types).
  def sync_ndjson_rows_count!
    return unless ndjson_file.attached?

    sync_ndjson_counts!
  end

  def verification_payload
    {
      expected_record_counts: normalized_expected_record_counts,
      readback: normalized_readback_verification
    }
  end

  def verification_status
    status = normalized_readback_verification["status"]
    status.in?(VERIFICATION_STATUSES) ? status : "not_verified"
  end

  def reset_readback_verification!
    update_columns(
      readback_verification: {
        "status" => "reverted",
        "checked_at" => Time.current.iso8601
      },
      updated_at: Time.current
    )
  end

  def revert
    super
    reset_readback_verification! if pending?
  end

  private

    def sync_ndjson_counts!
      line_counts = self.class.ndjson_line_type_counts(ndjson_blob_string)

      update_columns(
        rows_count: line_counts.values.sum,
        expected_record_counts: self.class.expected_record_counts_from_line_type_counts(line_counts),
        readback_verification: {},
        updated_at: Time.current
      )
    end

    def record_readback_verification!(before_counts:)
      update_columns(
        readback_verification: build_readback_verification(before_counts:, status_for_mismatch: "mismatch"),
        updated_at: Time.current
      )
    end

    def record_failed_readback_verification!(before_counts:, error:)
      return unless before_counts

      update_columns(
        readback_verification: build_readback_verification(before_counts:, status_for_mismatch: "failed").merge(
          "status" => "failed",
          "error" => error.message
        ),
        updated_at: Time.current
      )
    rescue => verification_error
      Rails.logger.warn("Failed to record Sure import readback verification for import #{id}: #{verification_error.message}")
    end

    def build_readback_verification(before_counts:, status_for_mismatch:)
      after_counts = readback_count_snapshot
      actual_delta_counts = delta_counts(before_counts, after_counts)
      expected_counts = normalized_expected_record_counts
      checked_counts = (actual_delta_counts.keys | expected_counts.keys).index_with do |key|
        expected_counts.fetch(key, 0).to_i
      end
      mismatches = checked_counts.each_with_object({}) do |(key, expected_count), result|
        actual_count = actual_delta_counts.fetch(key, 0)
        next if actual_count == expected_count.to_i

        result[key] = {
          "expected" => expected_count.to_i,
          "actual" => actual_count
        }
      end

      {
        "status" => mismatches.empty? ? "matched" : status_for_mismatch,
        "checked_at" => Time.current.iso8601,
        "expected_record_counts" => expected_counts,
        "before_counts" => before_counts,
        "after_counts" => after_counts,
        "actual_delta_counts" => actual_delta_counts,
        "checked_counts" => checked_counts,
        "mismatches" => mismatches
      }
    end

    def readback_count_snapshot
      {
        accounts: family.accounts.count,
        balances: Balance.joins(:account).where(accounts: { family_id: family.id }).count,
        categories: family.categories.count,
        tags: family.tags.count,
        merchants: family.merchants.count,
        recurring_transactions: family.recurring_transactions.count,
        transactions: family.entries.where(entryable_type: "Transaction").count,
        transfers: Transfer.joins(inflow_transaction: { entry: :account }).where(accounts: { family_id: family.id }).count,
        rejected_transfers: RejectedTransfer.joins(inflow_transaction: { entry: :account }).where(accounts: { family_id: family.id }).count,
        trades: family.entries.where(entryable_type: "Trade").count,
        holdings: family.holdings.count,
        valuations: family.entries.where(entryable_type: "Valuation").count,
        budgets: family.budgets.count,
        budget_categories: family.budget_categories.count,
        rules: family.rules.count
      }.transform_keys(&:to_s).transform_values(&:to_i)
    end

    def delta_counts(before_counts, after_counts)
      after_counts.each_with_object({}) do |(key, after_count), result|
        result[key] = after_count.to_i - before_counts.fetch(key, 0).to_i
      end
    end

    def normalized_expected_record_counts
      (expected_record_counts || {}).to_h.transform_keys(&:to_s).transform_values(&:to_i)
    end

    def normalized_readback_verification
      (readback_verification || {}).to_h.deep_stringify_keys
    end

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
