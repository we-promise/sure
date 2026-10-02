class TransactionImport < Import
  store_accessor :column_mappings, :date_basis, :date_timezone
  PreparedRow = Data.define(:row, :account, :currency, :date, :source_date, :timestamp, :amount, :sure_entry_id)
  private_constant :PreparedRow

  validates :date_basis, inclusion: { in: %w[source local] }, allow_blank: true
  validate :valid_date_timezone
  before_validation :reset_date_detection

  def date_format_options
    Family::DATE_FORMATS + CSV_ONLY_DATE_FORMATS + [ [ I18n.t("imports.timestamps.iso8601"), "iso8601" ] ]
  end

  def raw_date_samples
    csv_rows.map { |row| csv_value(row, date_col_label, "date") }
  end

  def date_detection
    @date_detection ||= DateParser.detect(raw_date_samples)
  end

  def valid_date_formats_with_preview
    sample = raw_date_samples.find(&:present?)
    return [] unless sample

    date_format_options.filter_map do |label, format|
      next unless date_detection.formats.include?(format)

      parsed = date_preview(format: format)
      { label: label, format: format, preview: parsed.date.iso8601, timestamp: parsed.timestamp }
    rescue ArgumentError
      # A malformed separate timestamp must not prevent changing its mapping.
      next
    end
  end

  def timestamp_timezone
    date_timezone.presence || Time.find_zone(family.timezone)&.tzinfo&.name || Rails.application.config.time_zone
  end

  def current_date_for_row(row)
    if date_format == "iso8601" && date_basis != "local"
      Time.current.getlocal(Entry::Timestamp.parse(row.date).utc_offset).to_date
    else
      Time.current.in_time_zone(timestamp_timezone).to_date
    end
  end

  def parse_row_date(row, format: date_format)
    parsed = super(row, format: format, strict: true)
    if format == "iso8601" && date_basis == "local"
      date_timestamp = row.transacted_at.present? ? DateParser.parse(row.date, format: format).timestamp : parsed.timestamp
      DateParser::Parsed.new(date: date_timestamp.in_time_zone(timestamp_timezone).to_date, timestamp: parsed.timestamp)
    else
      parsed
    end
  end

  def date_preview(format: date_format)
    format = date_detection.format if format == "auto"
    sample = csv_rows.find { |row| csv_value(row, date_col_label, "date").present? }
    return unless format.present? && sample

    row = Import::Row.new(date: csv_value(sample, date_col_label, "date"),
                          transacted_at: csv_value(sample, timestamp_col_label))
    parse_row_date(row, format: format)
  end

  def generate_rows_from_csv
    self.date_timezone = timestamp_timezone
    if date_format == "auto"
      unless date_detection.status == :detected
        errors.add(:date_format, I18n.t("imports.timestamps.#{date_detection.status}"))
        raise ActiveRecord::RecordInvalid, self
      end
      self.date_format = date_detection.format
    end
    save!
    super
  end

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      new_transactions = []
      updated_entries = []
      prepared_rows = prepare_rows
      matches = match_rows(prepared_rows)

      prepared_rows.each do |prepared|
        row = prepared.row
        timestamp = prepared.timestamp
        duplicate_entry = matches[row.id]
        category = mappings.categories.mappable_for(row.category)
        tags = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

        if duplicate_entry
          # Update existing transaction instead of creating a new one
          duplicate_entry.transaction.category = category if category.present?
          duplicate_entry.transaction.tags = tags if tags.any?
          duplicate_entry.notes = row.notes if row.notes.present?
          duplicate_entry.import = self
          duplicate_entry.import_locked = true  # Protect from provider sync overwrites
          if timestamp
            duplicate_entry.transacted_at = timestamp unless duplicate_entry.locked?(:transacted_at) || duplicate_entry.split_child?
            source = duplicate_entry.transaction.extra.fetch("csv", {}).dup
            source["transacted_at"] ||= timestamp.getutc.iso8601(6)
            source["date"] ||= prepared.source_date.iso8601
            duplicate_entry.transaction.extra = duplicate_entry.transaction.extra.deep_merge("csv" => source)
          end
          updated_entries << duplicate_entry
        else
          # Create new transaction (no duplicate found)
          # Mark as import_locked to protect from provider sync overwrites
          csv_extra = { "date" => prepared.source_date.iso8601 }
          csv_extra["transacted_at"] = timestamp.getutc.iso8601(6) if timestamp
          csv_extra["sure_entry_ids"] = [ prepared.sure_entry_id.downcase ] if prepared.sure_entry_id.present?
          new_transactions << Transaction.new(
            category: category,
            tags: tags,
            extra: timestamp || prepared.sure_entry_id.present? ? { "csv" => csv_extra } : {},
            entry: Entry.new(
              account: prepared.account,
              date: prepared.date,
              transacted_at: timestamp,
              amount: prepared.amount,
              name: row.name,
              currency: prepared.currency,
              notes: row.notes,
              import: self,
              import_locked: true
            )
          )
        end
      end

      # Save updated entries first
      updated_entries.each do |entry|
        entry.transaction.save!
        entry.save!
      end

      # Bulk import new transactions
      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
    end
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    base = %i[date amount name currency category tags notes]
    base.insert(1, :transacted_at) if timestamp_col_label.present?
    base.unshift(:account) if account.nil?
    base
  end

  def mapping_steps
    base = [ Import::CategoryMapping, Import::TagMapping ]
    base << Import::AccountMapping if account.nil?
    base
  end

  def selectable_amount_type_values
    return [] if entity_type_col_label.nil?

    csv_rows.map { |row| row[entity_type_col_label] }.uniq
  end

  def csv_template
    template = <<~CSV
      date*,amount*,name,currency,category,tags,account,notes
      2024-05-15,-45.99,Grocery Store,USD,Food,groceries|essentials,Checking Account,Monthly grocery run
      2024-05-16,1500.00,Salary,,Income,,Main Account,
      2024-05-17,-12.50,Coffee Shop,,,coffee,,
    CSV

    csv = CSV.parse(template, headers: true)
    csv.delete("account") if account.present?
    csv
  end

  private
    def prepare_rows
      rows_ordered.map do |row|
        mapped_account = account || mappings.accounts.mappable_for(row.account)
        unless mapped_account
          message = "Row #{row.source_row_number}: Account '#{row.account.presence || '(blank)'}' is not mapped to an existing account. " \
                    "Please map this account in the import configuration."
          errors.add(:base, message)
          raise Import::MappingError, message
        end
        parsed = parse_row_date(row)
        currency = currency_col_label.present? ? row.currency : (mapped_account.currency.presence || family.currency)
        PreparedRow.new(row: row, account: mapped_account, currency: currency,
                        date: parsed.date, source_date: DateParser.parse(row.date, format: date_format).date,
                        timestamp: parsed.timestamp, amount: row.signed_amount,
                        sure_entry_id: csv_value(csv_rows[row.source_row_number - 1], "sure_entry_id"))
      end
    end

    def match_rows(prepared_rows)
      matches = {}
      claimed = Set.new
      exported_ids = Set.new
      prepared_rows.each do |prepared|
        id = prepared.sure_entry_id
        next if id.blank?

        raise_ambiguous_match(prepared) unless id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i) && exported_ids.add?(id.downcase)

        candidates = prepared.account.entries
          .joins("INNER JOIN transactions AS csv_transactions ON csv_transactions.id = entries.entryable_id")
          .where(entryable_type: "Transaction")
        entry = candidates.find_by(id: id)
        unless entry
          aliases = candidates.where("(csv_transactions.extra -> 'csv' -> 'sure_entry_ids') @> CAST(:ids AS jsonb)",
                                     ids: [ id.downcase ].to_json)
          parents = aliases.where(parent_entry_id: nil).limit(2).to_a
          raise_ambiguous_match(prepared) if parents.many?
          children = parents.empty? ? aliases.limit(2).to_a : []
          raise_ambiguous_match(prepared) if children.many?
          entry = parents.first || children.first
        end
        next unless entry
        raise_ambiguous_match(prepared) if claimed.include?(entry.id)

        unless entry.date == prepared.date && entry.transacted_at == prepared.timestamp &&
               entry.name == prepared.row.name && entry.amount == prepared.amount && entry.currency == prepared.currency
          raise_ambiguous_match(prepared)
        end

        matches[prepared.row.id] = entry
        claimed.add(entry.id)
      end

      # Reserve same-date matches for every row before trying cross-date matches;
      # CSV row order must not let another accounting day claim them first.
      [ false, true ].each do |allow_cross_date|
        prepared_rows.select(&:timestamp).each do |prepared|
          next if prepared.sure_entry_id.present? || matches.key?(prepared.row.id)

          entry = find_row_match(prepared, claimed, allow_legacy: false, allow_cross_date: allow_cross_date)
          next unless entry

          matches[prepared.row.id] = entry
          claimed.add(entry.id)
        end
      end

      unresolved = prepared_rows.reject { |prepared| prepared.sure_entry_id.present? || matches.key?(prepared.row.id) }
      counts = unresolved.each_with_object(Hash.new(0)) do |prepared, result|
        result[match_key(prepared, prepared.date)] += 1
      end
      unresolved.sort_by { |prepared| [ prepared.timestamp ? 0 : 1, prepared.row.source_row_number ] }.each do |prepared|
        entry = find_row_match(prepared, claimed, allow_legacy: true)
        next unless entry

        if prepared.timestamp && counts[match_key(prepared, entry.date)] > 1
          raise Import::MappingError, I18n.t("imports.timestamps.ambiguous_match", row: prepared.row.source_row_number)
        end
        matches[prepared.row.id] = entry
        claimed.add(entry.id)
      end
      matches
    end

    def find_row_match(prepared, claimed, allow_legacy:, allow_cross_date: true)
      Account::ProviderImportAdapter.new(prepared.account).find_duplicate_transaction(
        date: prepared.date, amount: prepared.amount, currency: prepared.currency, name: prepared.row.name,
        exclude_entry_ids: claimed, csv_timestamp: prepared.timestamp, csv_dates: [ prepared.date ], csv_source_date: prepared.source_date,
        allow_legacy_timestamp_match: allow_legacy, allow_cross_date_timestamp_match: allow_cross_date
      )
    rescue Account::ProviderImportAdapter::AmbiguousTimestampMatch
      raise Import::MappingError, I18n.t("imports.timestamps.ambiguous_match", row: prepared.row.source_row_number)
    end

    def match_key(prepared, date)
      [ prepared.account.id, prepared.amount, prepared.currency, prepared.row.name, date ]
    end

    def raise_ambiguous_match(prepared)
      raise Import::MappingError, I18n.t("imports.timestamps.ambiguous_match", row: prepared.row.source_row_number)
    end

    def reset_date_detection
      @date_detection = nil
      if will_save_change_to_raw_file_str? || will_save_change_to_rows_to_skip? || will_save_change_to_col_sep?
        remove_instance_variable(:@parsed_csv) if defined?(@parsed_csv)
        @csv_rows = @csv_sample = @normalized_csv_headers = nil
      end
    end

    def valid_date_timezone
      return if date_timezone.blank? || ActiveSupport::TimeZone[date_timezone]

      errors.add(:date_timezone, :invalid)
    end
end
