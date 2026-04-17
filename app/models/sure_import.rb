require "zip"

class SureImport < Import
  MAX_NDJSON_SIZE = 10.megabytes
  ALLOWED_NDJSON_CONTENT_TYPES = %w[
    application/x-ndjson
    application/ndjson
    application/json
    application/octet-stream
    text/plain
  ].freeze

  has_one_attached :ndjson_file, dependent: :purge_later

  class << self
    def extract_ndjson_content(uploaded_file)
      return nil unless uploaded_file.present?

      ext = File.extname(uploaded_file.original_filename.to_s).downcase
      raw_content = uploaded_file.read
      uploaded_file.rewind

      content =
        if ext == ".zip"
          extract_all_ndjson_from_zip(raw_content)
        else
          raw_content
        end

      if content.respond_to?(:read)
        content.rewind if content.respond_to?(:rewind)
        content = content.read
      end

      return nil if content.nil?

      content = content.to_s
      content.force_encoding(Encoding::UTF_8)
      content.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
    end

    def zip_upload?(uploaded_file)
      File.extname(uploaded_file.original_filename.to_s).downcase == ".zip"
    end

    # Counts JSON lines by top-level "type" (used for dry-run summaries and row limits).
    def ndjson_line_type_counts(content)
      return {} unless content.present?

      counts = Hash.new(0)
      content.each_line do |line|
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

    def dry_run_totals_from_ndjson(content)
      counts = ndjson_line_type_counts(content)
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

    def valid_ndjson_first_line?(str)
      return false if str.blank?

      first_line = str.lines.first&.strip
      first_line = first_line&.sub(/\A\uFEFF/, "")
      return false if first_line.blank?

      begin
        record = JSON.parse(first_line)
        record.key?("type") && record.key?("data")
      rescue JSON::ParserError
        false
      end
    end

    private
      def extract_all_ndjson_from_zip(zip_content)
        fallback_ndjson = nil

        Zip::InputStream.open(StringIO.new(zip_content.b)) do |zip_stream|
          while (entry = zip_stream.get_next_entry)
            next if entry.name_is_directory?

            entry_name = File.basename(entry.name).downcase
            entry_ext = File.extname(entry_name).downcase
            entry_content = zip_stream.read

            return entry_content if entry_name == "all.ndjson"
            fallback_ndjson ||= entry_content if entry_ext == ".ndjson"
          end
        end

        fallback_ndjson
      rescue Zip::Error, Zlib::Error
        nil
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
    result = Import.transaction do
      replace_existing_family_data!

      importer = Family::DataImporter.new(family, ndjson_blob_string)
      importer.import!
    end

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

  def max_row_count
    100_000
  end

  # Row total for max-row enforcement (counts every parsed line with a "type", including unsupported types).
  def sync_ndjson_rows_count!
    return unless ndjson_file.attached?

    total = self.class.ndjson_line_type_counts(ndjson_blob_string).values.sum
    update_column(:rows_count, total)
  end

  private

    def replace_existing_family_data!
      # Remove dependent objects first, then core records.
      family.recurring_transactions.destroy_all
      family.rules.destroy_all
      family.budgets.destroy_all
      family.accounts.destroy_all
      family.tags.destroy_all
      family.categories.destroy_all
      family.merchants.destroy_all
    end

    def ndjson_blob_string
      ndjson_file.download.force_encoding(Encoding::UTF_8)
    end
end
