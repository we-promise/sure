class Import < ApplicationRecord
  MaxRowCountExceededError = Class.new(StandardError)
  MappingError = Class.new(StandardError)

  MAX_CSV_SIZE = 10.megabytes
  MAX_PDF_SIZE = 25.megabytes
  ALLOWED_CSV_MIME_TYPES = %w[text/csv text/plain application/vnd.ms-excel application/csv].freeze
  ALLOWED_PDF_MIME_TYPES = %w[application/pdf].freeze

  DOCUMENT_TYPES = %w[bank_statement credit_card_statement investment_statement financial_document contract other].freeze

  TYPES = %w[TransactionImport TradeImport AccountImport MintImport CategoryImport RuleImport PdfImport].freeze
  SIGNAGE_CONVENTIONS = %w[inflows_positive inflows_negative]
  SEPARATORS = [ [ "Comma (,)", "," ], [ "Semicolon (;)", ";" ] ].freeze

  NUMBER_FORMATS = {
    "1,234.56" => { separator: ".", delimiter: "," },  # US/UK/Asia
    "1.234,56" => { separator: ",", delimiter: "." },  # Most of Europe
    "1 234,56" => { separator: ",", delimiter: " " },  # French/Scandinavian
    "1,234"    => { separator: "",  delimiter: "," }   # Zero-decimal currencies like JPY
  }.freeze

  AMOUNT_TYPE_STRATEGIES = %w[signed_amount custom_column].freeze

  belongs_to :family
  belongs_to :account, optional: true

  before_validation :set_default_number_format
  before_validation :ensure_utf8_encoding

  scope :ordered, -> { order(created_at: :desc) }

  enum :status, {
    pending: "pending",
    complete: "complete",
    importing: "importing",
    reverting: "reverting",
    revert_failed: "revert_failed",
    failed: "failed"
  }, validate: true, default: "pending"

  validates :type, inclusion: { in: TYPES }
  validates :amount_type_strategy, inclusion: { in: AMOUNT_TYPE_STRATEGIES }
  validates :col_sep, inclusion: { in: SEPARATORS.map(&:last) }
  validates :signage_convention, inclusion: { in: SIGNAGE_CONVENTIONS }, allow_nil: true
  validates :number_format, presence: true, inclusion: { in: NUMBER_FORMATS.keys }
  validate :custom_column_import_requires_identifier
  validates :rows_to_skip, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :account_belongs_to_family
  validate :rows_to_skip_within_file_bounds

  has_many :rows, dependent: :destroy
  has_many :mappings, dependent: :destroy
  has_many :accounts, dependent: :destroy
  has_many :entries, dependent: :destroy

  class << self
    def parse_csv_str(csv_str, col_sep: ",")
      CSV.parse(
        (csv_str || "").strip,
        headers: true,
        col_sep: col_sep,
        converters: [ ->(str) { str&.strip } ],
        liberal_parsing: true
      )
    end
  end

  def publish_later
    raise MaxRowCountExceededError if row_count_exceeded?
    raise "Import is not publishable" unless publishable?

    update! status: :importing

    ImportJob.perform_later(self)
  end

  def publish
    raise MaxRowCountExceededError if row_count_exceeded?

    import!

    family.sync_later

    update! status: :complete
  rescue => error
    update! status: :failed, error: error.message
  end

  def revert_later
    raise "Import is not revertable" unless revertable?

    update! status: :reverting

    RevertImportJob.perform_later(self)
  end

  def revert
    Import.transaction do
      accounts.destroy_all
      entries.destroy_all
    end

    family.sync_later

    update! status: :pending
  rescue => error
    update! status: :revert_failed, error: error.message
  end

  def csv_rows
    @csv_rows ||= parsed_csv
  end

  def csv_headers
    parsed_csv.headers
  end

  def csv_sample
    @csv_sample ||= parsed_csv.first(2)
  end

  def dry_run
    mappings = {
      transactions: rows_count,
      categories: Import::CategoryMapping.for_import(self).creational.count,
      tags: Import::TagMapping.for_import(self).creational.count
    }

    mappings.merge(
      accounts: Import::AccountMapping.for_import(self).creational.count,
    ) if account.nil?

    mappings
  end

  def required_column_keys
    []
  end

  # Returns false for import types that don't need CSV column mapping (e.g., PdfImport).
  # Override in subclasses that handle data extraction differently.
  def requires_csv_workflow?
    true
  end

  # Subclasses that require CSV workflow must override this.
  # Non-CSV imports (e.g., PdfImport) can return [].
  def column_keys
    raise NotImplementedError, "Subclass must implement column_keys"
  end

  def generate_rows_from_csv
    rows.destroy_all

    mapped_rows = csv_rows.map do |row|
      {
        account: row[account_col_label].to_s,
        date: row[date_col_label].to_s,
        qty: sanitize_number(row[qty_col_label]).to_s,
        ticker: row[ticker_col_label].to_s,
        exchange_operating_mic: row[exchange_operating_mic_col_label].to_s,
        price: sanitize_number(row[price_col_label]).to_s,
        amount: sanitize_number(row[amount_col_label]).to_s,
        currency: (row[currency_col_label] || default_currency).to_s,
        name: (row[name_col_label] || default_row_name).to_s,
        category: row[category_col_label].to_s,
        tags: row[tags_col_label].to_s,
        entity_type: row[entity_type_col_label].to_s,
        notes: row[notes_col_label].to_s
      }
    end

    rows.insert_all!(mapped_rows)
    update_column(:rows_count, rows.count)
  end

  def sync_mappings
    transaction do
      mapping_steps.each do |mapping_class|
        mappables_by_key = mapping_class.mappables_by_key(self)

        updated_mappings = mappables_by_key.map do |key, mappable|
          mapping = mappings.find_or_initialize_by(key: key, import: self, type: mapping_class.name)
          mapping.mappable = mappable
          mapping.create_when_empty = key.present? && mappable.nil?
          mapping
        end

        updated_mappings.each { |m| m.save(validate: false) }
        mapping_class.where.not(id: updated_mappings.map(&:id)).destroy_all
      end
    end
  end

  def mapping_steps
    []
  end

  def uploaded?
    raw_file_str.present?
  end

  def configured?
    uploaded? && rows_count > 0
  end

  def cleaned?
    configured? && rows.all?(&:valid?)
  end

  def publishable?
    cleaned? && mappings.all?(&:valid?)
  end

  def revertable?
    complete? || revert_failed?
  end

  def has_unassigned_account?
    mappings.accounts.where(key: "").any?
  end

  def requires_account?
    family.accounts.empty? && has_unassigned_account?
  end

  # Used to optionally pre-fill the configuration for the current import
  def suggested_template
    family.imports
          .complete
          .where(account: account, type: type)
          .order(created_at: :desc)
          .first
  end

  def apply_template!(import_template)
    update!(
      import_template.attributes.slice(
        "date_col_label", "amount_col_label", "name_col_label",
        "category_col_label", "tags_col_label", "account_col_label",
        "qty_col_label", "ticker_col_label", "price_col_label",
        "entity_type_col_label", "notes_col_label", "currency_col_label",
        "date_format", "signage_convention", "number_format",
        "exchange_operating_mic_col_label",
        "rows_to_skip"
      )
    )
  end

  def max_row_count
    10000
  end

  private
    def row_count_exceeded?
      rows_count > max_row_count
    end

    def import!
      # no-op, subclasses can implement for customization of algorithm
    end

    def default_row_name
      "Imported item"
    end

    def default_currency
      account&.currency || family.currency
    end

    def parsed_csv
      return @parsed_csv if defined?(@parsed_csv)

      csv_content = raw_file_str || ""
      if rows_to_skip.to_i > 0
        csv_content = csv_content.lines.drop(rows_to_skip).join
      end

      @parsed_csv = self.class.parse_csv_str(csv_content, col_sep: col_sep)
    end

    def sanitize_number(value)
      return "" if value.nil?

      format = NUMBER_FORMATS[number_format]
      return "" unless format

      # First, normalize spaces and remove any characters that aren't numbers, delimiters, separators, or minus signs
      sanitized = value.to_s.strip

      # Handle French/Scandinavian format specially
      if format[:delimiter] == " "
        sanitized = sanitized.gsub(/\s+/, "") # Remove all spaces first
      else
        sanitized = sanitized.gsub(/[^\d#{Regexp.escape(format[:delimiter])}#{Regexp.escape(format[:separator])}\-]/, "")

        # Replace delimiter with empty string
        if format[:delimiter].present?
          sanitized = sanitized.gsub(format[:delimiter], "")
        end
      end

      # Replace separator with period for proper float parsing
      if format[:separator].present?
        sanitized = sanitized.gsub(format[:separator], ".")
      end

      # Return empty string if not a valid number
      unless sanitized =~ /\A-?\d+\.?\d*\z/
        return ""
      end

      sanitized
    end

    def set_default_number_format
      self.number_format ||= "1,234.56" # Default to US/UK format
    end

    def custom_column_import_requires_identifier
      return unless amount_type_strategy == "custom_column"

      if amount_type_inflow_value.blank?
        errors.add(:base, I18n.t("imports.errors.custom_column_requires_inflow"))
      end
    end

    # Common encodings to try when UTF-8 detection fails
    # Windows-1250 is prioritized for Central/Eastern European languages
    COMMON_ENCODINGS = [ "Windows-1250", "Windows-1252", "ISO-8859-1", "ISO-8859-2" ].freeze

    def ensure_utf8_encoding
      # Handle nil or empty string first (before checking if changed)
      return if raw_file_str.nil? || raw_file_str.bytesize == 0

      # Only process if the attribute was changed
      # Use will_save_change_to_attribute? which is safer for binary data
      return unless will_save_change_to_raw_file_str?

      # If already valid UTF-8, nothing to do
      begin
        if raw_file_str.encoding == Encoding::UTF_8 && raw_file_str.valid_encoding?
          return
        end
      rescue ArgumentError
        # raw_file_str might have invalid encoding, continue to detection
      end

      # Detect encoding using rchardet
      begin
        require "rchardet"
        detection = CharDet.detect(raw_file_str)
        detected_encoding = detection["encoding"]
        confidence = detection["confidence"]

        # Only convert if we have reasonable confidence in the detection
        if detected_encoding && confidence > 0.75
          # Force encoding and convert to UTF-8
          self.raw_file_str = raw_file_str.force_encoding(detected_encoding).encode("UTF-8", invalid: :replace, undef: :replace)
        else
          # Fallback: try common encodings
          try_common_encodings
        end
      rescue LoadError
        # rchardet not available, fallback to trying common encodings
        try_common_encodings
      rescue ArgumentError, Encoding::CompatibilityError => e
        # Handle encoding errors by falling back to common encodings
        try_common_encodings
      end
    end

    def try_common_encodings
      COMMON_ENCODINGS.each do |encoding|
        begin
          test = raw_file_str.dup.force_encoding(encoding)
          if test.valid_encoding?
            self.raw_file_str = test.encode("UTF-8", invalid: :replace, undef: :replace)
            return
          end
        rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
          next
        end
      end

      # If nothing worked, force UTF-8 and replace invalid bytes
      self.raw_file_str = raw_file_str.force_encoding("UTF-8").scrub("?")
    end

    def account_belongs_to_family
      return if account.nil?
      return if account.family_id == family_id

      errors.add(:account, "must belong to your family")
    end

    def rows_to_skip_within_file_bounds
      return if raw_file_str.blank?
      return if rows_to_skip.to_i == 0

      line_count = raw_file_str.lines.count

      if rows_to_skip.to_i >= line_count
        errors.add(:rows_to_skip, "must be less than the number of lines in the file (#{line_count})")
      end
    end
end
