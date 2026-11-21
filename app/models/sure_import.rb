class SureImport < Import
  PreflightError = Class.new(StandardError)

  DEFAULT_MAX_NDJSON_SIZE_MB = 10
  DEFAULT_MAX_ROW_COUNT = 100_000
  # Ids per UPDATE batch when linking created records to the import.
  LINK_BATCH_SIZE = 1_000
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

  # From the record counts stored with the file (#sync_ndjson_rows_count!,
  # run on every upload and before a publish), so a check under a lock
  # doesn't download it; imports from before those counts read the file.
  def writes_rules?
    counts = normalized_expected_record_counts
    return counts["rules"].to_i.positive? if counts.key?("rules")

    ndjson_file.attached? && self.class.ndjson_line_type_counts(ndjson_blob_string)["Rule"].to_i.positive?
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
    importer = Family::DataImporter.new(family, ndjson_blob_string, import_session: import_session, import: self, user: importing_user(import_session))
    result = importer.import!

    # DataImporter doesn't set import_id, so link the records it created here.
    # Done by hand instead of `accounts.concat` / `entries.concat`: those load
    # the association and need every record in memory at once, while this holds
    # at most one batch of records at a time. Don't replace it with update_all,
    # which would skip callbacks.
    Import.transaction do
      # IS DISTINCT FROM, not `!=`: a NULL import_id must match too.
      result[:account_ids].each_slice(LINK_BATCH_SIZE) do |ids|
        family.accounts.where(id: ids).where("accounts.import_id IS DISTINCT FROM ?", id)
          .find_each { |account| account.update!(import_id: id) }
      end
      result[:entry_ids].each_slice(LINK_BATCH_SIZE) do |ids|
        family.entries.where(id: ids).where("entries.import_id IS DISTINCT FROM ?", id)
          .find_each { |entry| entry.update!(import_id: id) }
      end
      update!(summary: result[:summary]) if has_attribute?(:summary)
    end

    record_readback_verification!(
      before_counts:,
      reused_counts: reused_counts_from(result[:summary]),
      created_counts: created_counts_from(result[:summary])
    )
    result
  rescue => error
    record_failed_readback_verification!(before_counts:, error:)
    raise
  end

  def publish_later(user:)
    # The counts the claim's checks read (#writes_rules?) match the file now.
    sync_ndjson_rows_count!
    raise MaxRowCountExceededError if row_count_exceeded?

    validate_sure_preflight!
    raise NotPublishableError, "Import was uploaded but has no publishable records." unless publishable?

    super
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
    # Who imports, for the rules it brings (Family::DataImporter). A
    # session's rules belong to who opened it, even when an admin publishes,
    # and only while they are still in this family.
    def importing_user(import_session)
      return published_by unless import_session

      creator = import_session.created_by
      creator if creator&.family_id == family_id
    end


    def sync_ndjson_counts!
      line_counts = self.class.ndjson_line_type_counts(ndjson_blob_string)

      update_columns(
        rows_count: line_counts.values.sum,
        expected_record_counts: self.class.expected_record_counts_from_line_type_counts(line_counts),
        readback_verification: {},
        updated_at: Time.current
      )
    end

    # Category/Tag/Merchant rows matched to an existing family record by name, and Budget/
    # BudgetCategory rows merged into the family's untouched default budget, are "updated",
    # not created, so they add nothing to the readback delta.
    def reused_counts_from(summary)
      %w[categories tags merchants budgets budget_categories].index_with { |key| (summary || {}).dig(key, "updated").to_i }
    end

    # A ProviderMerchant row with no shared match yet becomes a FamilyMerchant
    # (see Family::DataImporter#import_provider_merchants), which isn't counted
    # under the "Merchant" NDJSON line type, so its creation must be added to
    # the expected merchant delta explicitly.
    def created_counts_from(summary)
      { "merchants" => (summary || {}).dig("provider_merchants", "created").to_i }
    end

    def record_readback_verification!(before_counts:, reused_counts: {}, created_counts: {})
      update_columns(
        readback_verification: build_readback_verification(before_counts:, status_for_mismatch: "mismatch", reused_counts:, created_counts:),
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

    def build_readback_verification(before_counts:, status_for_mismatch:, reused_counts: {}, created_counts: {})
      after_counts = readback_count_snapshot
      actual_delta_counts = delta_counts(before_counts, after_counts)
      expected_counts = normalized_expected_record_counts
      expected_creations = expected_counts.merge(created_counts) { |_key, expected, created| expected + created }
      expected_creations = expected_creations.merge(reused_counts) { |_key, expected, reused| [ expected - reused, 0 ].max }
      checked_counts = (actual_delta_counts.keys | expected_counts.keys).index_with do |key|
        expected_creations.fetch(key, 0).to_i
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
        "reused_record_counts" => reused_counts.select { |_key, count| count.positive? },
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

    # Marks the import failed only while it can still change: another
    # request may have published a corrected file meanwhile.
    def validate_sure_preflight!
      result = sure_preflight
      return if result.valid?

      with_lock { update!(status: :failed, error: result.error_message) if changeable? }
      raise PreflightError, result.error_message
    end
end
